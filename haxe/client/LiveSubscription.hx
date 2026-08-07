/** Handle bound to one immutable subscription generation. */
class LiveSubscription {
  final owner:LiveOwner;
  public final id:String;
  public final generation:Int;

  public function new(owner:LiveOwner, id:String, generation:Int) {
    this.owner = owner;
    this.id = id;
    this.generation = generation;
  }

  public function next(timeout:Float):LiveEvent {
    return owner.next(id, generation, timeout);
  }

  public function close():Void {
    owner.unsubscribeGeneration(id, generation);
  }
}
