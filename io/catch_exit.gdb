set pagination off
set breakpoint pending on
break /src/io/libs/basekit/source/Stack.c:114
break /src/io/libs/iovm/source/IoList.c:147
break /src/io/libs/iovm/source/IoToken.c:108
break /src/io/libs/iovm/source/IoLexer.c:426
break /src/io/libs/iovm/source/IoLexer.c:500
break /src/io/libs/basekit/source/BStream.c:529
break /src/io/libs/iovm/source/IoState_exceptions.c:20
break /src/io/libs/iovm/source/IoState_debug.c:79
break /src/io/libs/iovm/source/IoState_debug.c:88
break /src/io/libs/basekit/source/UArray.c:155
break /src/io/libs/basekit/source/UArray.c:160
break /src/io/libs/basekit/source/UArray.c:368
break /src/io/libs/basekit/source/UArray.c:469
break /src/io/libs/garbagecollector/source/Collector.c:85
run /project/client/tests/run.io
bt 40
info breakpoints
quit
