import haxe.Json;
import haxe.io.Bytes;

/** Strict JSON helpers shared by the client and conformance adapter. */
class JsonTools {
  static inline var MAX_JSON_DEPTH = 128;
  static inline var MAX_JSON_NODES = 65536;

  public static function isObject(value:Dynamic):Bool {
    return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array) && !Std.isOfType(value, String);
  }

  public static function requireObject(value:Dynamic, label:String):Dynamic {
    if (!isObject(value)) throw ConvexError.protocol('$label was not a JSON object');
    return value;
  }

  public static function requireString(object:Dynamic, field:String, label:String):String {
    if (!Reflect.hasField(object, field) || !Std.isOfType(Reflect.field(object, field), String)) {
      throw ConvexError.protocol('$label.$field must be a string');
    }
    return Reflect.field(object, field);
  }

  public static function stringArray(value:Dynamic, label:String):Array<String> {
    if (!Std.isOfType(value, Array)) throw ConvexError.protocol('$label must be an array of strings');
    var result:Array<String> = [];
    for (item in (cast value:Array<Dynamic>)) {
      if (!Std.isOfType(item, String)) throw ConvexError.protocol('$label must contain only strings');
      result.push(item);
    }
    return result;
  }

  /** Missing logs mean no logs. An explicit JSON null is different and is
   * rejected instead of being silently normalised into a valid envelope. */
  public static function optionalStringArray(object:Dynamic, field:String, label:String):Array<String> {
    return Reflect.hasField(object, field) ? stringArray(Reflect.field(object, field), label) : [];
  }

  /** Neko strings are UTF-8 byte sequences. Count decoded scalar values rather
   * than bytes so the adapter's JSON Schema boundary is portable. */
  public static function codePoints(value:String):Int {
    return Utf8Text.codePoints(value);
  }

  public static function encodedBytes(value:Dynamic):Int {
    return Bytes.ofString(Json.stringify(value)).length;
  }

  /** Bound parser work before handing attacker-controlled bytes to Haxe's
   * recursive JSON decoder. Braces inside strings and escaped quotes do not
   * affect the structural count; the JSON parser still owns syntax validity. */
  public static function checkJsonShape(bytes:Bytes, label:String):Void {
    var depth = 0;
    var nodes = 1;
    var quoted = false;
    var escaped = false;
    for (index in 0...bytes.length) {
      var byte = bytes.get(index);
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (byte == 0x5C) {
          escaped = true;
        } else if (byte == 0x22) {
          quoted = false;
        }
        continue;
      }
      if (byte == 0x22) {
        quoted = true;
      } else if (byte == 0x7B || byte == 0x5B) {
        depth++;
        nodes++;
        if (depth > MAX_JSON_DEPTH) throw ConvexError.protocol('$label exceeded 128 nesting levels');
      } else if (byte == 0x7D || byte == 0x5D) {
        depth--;
      } else if (byte == 0x2C) {
        nodes++;
      }
      if (nodes > MAX_JSON_NODES) throw ConvexError.protocol('$label exceeded 65536 structural nodes');
    }
  }

  public static function exactInteger(value:Dynamic, label:String):Int {
    if (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)) {
      throw ConvexError.protocol('$label must be an integer');
    }
    var number:Float = value;
    if (!Math.isFinite(number) || Math.floor(number) != number || number < -2147483648.0 || number > 2147483647.0) {
      throw ConvexError.protocol('$label must be an in-range integer');
    }
    return Std.int(number);
  }

  /** Neko's target integer is signed. Sync fields are unsigned, so this
   * client supports the non-negative half exactly and rejects values it cannot
   * represent without wrapping. */
  public static function nonNegativeInteger(value:Dynamic, label:String):Int {
    var number = exactInteger(value, label);
    if (number < 0) throw ConvexError.protocol('$label must be non-negative');
    return number;
  }

  public static function allowedFields(object:Dynamic, allowed:Array<String>, label:String):Void {
    for (field in Reflect.fields(object)) {
      if (allowed.indexOf(field) < 0) throw ConvexError.protocol('$label has unknown field $field');
    }
  }
}
