set pagination off
set breakpoint pending on
break IoState_exit
run /project/client/tests/run.io
print returnCode
print self->currentCoroutine
call (void)IoCoroutine_rawPrintBackTrace(self->currentCoroutine)
bt 25
continue
quit
