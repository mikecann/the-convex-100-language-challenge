#!/usr/local/bin/php
<?php
declare(strict_types=1);
require getenv('CONVEX_CLIENT_PATH') ?: dirname(__DIR__, 2).'/convex.php';
use Convex\{Client,FunctionError,Error};

function emit($io,array $v):void { fwrite($io,json_encode($v,JSON_THROW_ON_ERROR|JSON_INVALID_UTF8_SUBSTITUTE)."\n"); fflush($io); }
function errorEvent(?string $id, \Throwable $e, ?string $subscriptionId=null):array { $x=['type'=>$subscriptionId?'subscription':'error','error'=>['name'=>(new ReflectionClass($e))->getShortName(),'message'=>$e->getMessage()]];if($id!==null)$x['id']=$id;if($subscriptionId!==null)$x['subscriptionId']=$subscriptionId;if($e instanceof FunctionError){$x['error']['data']=$e->data;$x['logs']=$e->logs;}return $x; }
function adapter($input,$output):void {
  $client=null;$subscriptions=[];$alive=true;
  while($alive){
    $read=[$input];$w=$e=[];stream_select($read,$w,$e,0,100000);
    if($read){$line=fgets($input);if($line===false)break;try{$c=json_decode($line,true,512,JSON_THROW_ON_ERROR);$id=$c['id']??null;switch($c['op']??''){
      case 'hello': if(($c['protocolVersion']??0)!==1)throw new \RuntimeException('unsupported adapter protocol');emit($output,['protocolVersion'=>1,'id'=>$id,'type'=>'ready','language'=>'php','implementation'=>'native-php-'.PHP_VERSION,'runtime'=>'php-'.PHP_VERSION]);break;
      case 'query':case 'mutation':case 'action':$client??=new Client(getenv('CONVEX_URL')?:throw new \RuntimeException('CONVEX_URL is required'),getenv('CONVEX_AUTH_TOKEN')?:null);$r=$client->{$c['op']}($c['path'],$c['args']);emit($output,['id'=>$id,'type'=>'result','value'=>$r->value,'logs'=>$r->logs]);break;
      case 'setAuth':$client??=new Client(getenv('CONVEX_URL')?:throw new \RuntimeException('CONVEX_URL is required'));$client->setAuth($c['token']);emit($output,['id'=>$id,'type'=>'ack']);break;
      case 'subscribe':$client??=new Client(getenv('CONVEX_URL')?:throw new \RuntimeException('CONVEX_URL is required'));if(isset($subscriptions[$c['subscriptionId']]))$subscriptions[$c['subscriptionId']]->close();$subscriptions[$c['subscriptionId']]=$client->subscribe($c['path'],$c['args']??[]);emit($output,['id'=>$id,'type'=>'ack']);break;
      case 'unsubscribe':if(isset($subscriptions[$c['subscriptionId']]))$subscriptions[$c['subscriptionId']]->close();unset($subscriptions[$c['subscriptionId']]);emit($output,['id'=>$id,'type'=>'ack']);break;
      case 'debugDisconnect':$client?->debugDisconnectForAdapter();emit($output,['id'=>$id,'type'=>'ack']);break;
      case 'close':foreach($subscriptions as $s)$s->close();$client?->close();emit($output,['id'=>$id,'type'=>'closed']);$alive=false;break;
      default:throw new \RuntimeException('unknown adapter operation');
    }}catch(\Throwable $x){emit($output,errorEvent($id??null,$x));}}
    if($client){try{$client->pump(0.0);foreach($subscriptions as $sid=>$s){while(true){try{$u=$s->nextUpdate(0.0001);}catch(\Convex\TransportError){break;}catch(\Convex\ClosedError){break;}if($u->error)emit($output,errorEvent(null,$u->error,$sid));else emit($output,['type'=>'subscription','subscriptionId'=>$sid,'value'=>$u->value,'logs'=>$u->logs]);}}}catch(\Throwable $x){foreach(array_keys($subscriptions) as $sid)emit($output,errorEvent(null,$x,$sid));}}
  }
}
$listen=getenv('ADAPTER_LISTEN');if($listen){$server=stream_socket_server('tcp://'.$listen,$errno,$errstr);if(!$server)throw new RuntimeException($errstr);$conn=stream_socket_accept($server,-1);adapter($conn,$conn);fclose($conn);fclose($server);}else adapter(STDIN,STDOUT);
