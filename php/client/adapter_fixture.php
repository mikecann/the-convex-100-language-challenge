<?php
declare(strict_types=1);
// TCP is the harness mode. This opens the real adapter process and confirms it
// responds immediately to hello and cleanly terminates after close.
$port=0;$probe=stream_socket_server('tcp://127.0.0.1:0',$n,$e);$port=(int)substr(strrchr(stream_socket_get_name($probe,false),':'),1);fclose($probe);
$pipes=[];$env=['ADAPTER_LISTEN'=>"127.0.0.1:$port",'CONVEX_CLIENT_PATH'=>__DIR__.'/convex.php'];$process=proc_open([PHP_BINARY,__DIR__.'/tests/conformance/adapter.php'],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,$env);
for($i=0;$i<30;$i++){ $socket=@stream_socket_client("tcp://127.0.0.1:$port",$x,$y,.05);if($socket)break;usleep(20000); }if(!$socket)throw new RuntimeException('adapter TCP did not listen');
fwrite($socket,"{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\"}\n");$ready=json_decode(fgets($socket),true,512,JSON_THROW_ON_ERROR);if(($ready['type']??'')!=='ready'||($ready['language']??'')!=='php')throw new RuntimeException('adapter hello serialization');
fwrite($socket,"{\"id\":\"c\",\"op\":\"close\"}\n");$closed=json_decode(fgets($socket),true,512,JSON_THROW_ON_ERROR);if(($closed['type']??'')!=='closed')throw new RuntimeException('adapter close serialization');fclose($socket);proc_close($process);echo "php adapter TCP fixture passed\n";
