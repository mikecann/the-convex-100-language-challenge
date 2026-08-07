%% Erlang side of Convex.Bytes.
%%
%% `Bytes` is an Erlang binary and `Chunks` is a reversed iolist. Nothing here
%% knows anything about Convex, HTTP, or JSON: these are the byte primitives
%% PureScript has no syntax for, plus three scans that would otherwise cost one
%% cross-language call per byte.
-module(convex_bytes@foreign).

-export([empty/0, size/1, append/2,
         fromString/1, toStringOrEmpty/1, isValidUtf8/1,
         byteAt/2, slice/3, indexOfByte/3, indexOfBytes/3,
         emptyChunks/0, pushChunk/2, chunksSize/1, chunksToBytes/1,
         singleByte/1, uint16BE/1, uint64BE/1, uint64LE/1,
         readUint16BE/2, readUint64BE/2, readUint64LE/2,
         xorRepeating/2,
         base64Encode/1, base64Decode/1, sha1/1,
         codepointToBytes/1,
         jsonStringStop/2, skipWhitespace/2]).

empty() -> <<>>.

size(Bytes) -> byte_size(Bytes).

append(Left, Right) -> <<Left/binary, Right/binary>>.

%% Strings are already UTF-8 binaries under purerl, so this is a type change.
fromString(Text) -> Text.

toStringOrEmpty(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end.

isValidUtf8(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Text when is_binary(Text) -> true;
        _ -> false
    end.

byteAt(Bytes, Index) when Index >= 0, Index < byte_size(Bytes) ->
    binary:at(Bytes, Index);
byteAt(_Bytes, _Index) ->
    -1.

slice(Bytes, Start, Length) ->
    Size = byte_size(Bytes),
    From = max(0, min(Start, Size)),
    Count = max(0, min(Length, Size - From)),
    binary:part(Bytes, From, Count).

indexOfByte(Bytes, Byte, From) when From >= 0, From =< byte_size(Bytes) ->
    Rest = binary:part(Bytes, From, byte_size(Bytes) - From),
    case binary:match(Rest, <<Byte>>) of
        nomatch -> -1;
        {Index, _} -> From + Index
    end;
indexOfByte(_Bytes, _Byte, _From) ->
    -1.

indexOfBytes(_Bytes, <<>>, From) ->
    From;
indexOfBytes(Bytes, Needle, From) when From >= 0, From =< byte_size(Bytes) ->
    Rest = binary:part(Bytes, From, byte_size(Bytes) - From),
    case binary:match(Rest, Needle) of
        nomatch -> -1;
        {Index, _} -> From + Index
    end;
indexOfBytes(_Bytes, _Needle, _From) ->
    -1.

emptyChunks() -> [].

pushChunk(Bytes, Chunks) -> [Bytes | Chunks].

chunksSize(Chunks) -> iolist_size(Chunks).

chunksToBytes(Chunks) -> iolist_to_binary(lists:reverse(Chunks)).

singleByte(Value) -> <<(Value band 16#FF)>>.

uint16BE(Value) -> <<(Value band 16#FFFF):16/big-unsigned-integer>>.

uint64BE(Value) -> <<Value:64/big-unsigned-integer>>.

uint64LE(Value) -> <<Value:64/little-unsigned-integer>>.

readUint16BE(Bytes, Index) when Index >= 0, Index + 2 =< byte_size(Bytes) ->
    <<Value:16/big-unsigned-integer>> = binary:part(Bytes, Index, 2),
    Value;
readUint16BE(_Bytes, _Index) ->
    -1.

readUint64BE(Bytes, Index) when Index >= 0, Index + 8 =< byte_size(Bytes) ->
    <<Value:64/big-unsigned-integer>> = binary:part(Bytes, Index, 8),
    Value;
readUint64BE(_Bytes, _Index) ->
    -1.

readUint64LE(Bytes, Index) when Index >= 0, Index + 8 =< byte_size(Bytes) ->
    <<Value:64/little-unsigned-integer>> = binary:part(Bytes, Index, 8),
    Value;
readUint64LE(_Bytes, _Index) ->
    -1.

xorRepeating(Data, <<>>) ->
    Data;
xorRepeating(Data, Key) ->
    _ = application:ensure_all_started(crypto),
    DataSize = byte_size(Data),
    KeySize = byte_size(Key),
    Repeated = binary:copy(Key, (DataSize + KeySize - 1) div KeySize),
    crypto:exor(Data, binary:part(Repeated, 0, DataSize)).

base64Encode(Bytes) -> base64:encode(Bytes).

base64Decode(Text) ->
    try
        base64:decode(Text)
    catch
        _:_ -> <<>>
    end.

sha1(Bytes) ->
    _ = application:ensure_all_started(crypto),
    crypto:hash(sha, Bytes).

%% Surrogates and out-of-range values are not scalar values, so they encode to
%% nothing and the JSON decoder reports the escape as invalid.
codepointToBytes(Value) when Value >= 0, Value =< 16#10FFFF,
                             (Value < 16#D800 orelse Value > 16#DFFF) ->
    <<Value/utf8>>;
codepointToBytes(_Value) ->
    <<>>.

%% Walk to the next byte that changes how a JSON string is decoded or encoded.
jsonStringStop(Bytes, Index) when Index < 0 ->
    jsonStringStop(Bytes, 0);
jsonStringStop(Bytes, Index) when Index >= byte_size(Bytes) ->
    byte_size(Bytes);
jsonStringStop(Bytes, Index) ->
    case binary:at(Bytes, Index) of
        16#22 -> Index;
        16#5C -> Index;
        Byte when Byte < 16#20 -> Index;
        _ -> jsonStringStop(Bytes, Index + 1)
    end.

skipWhitespace(Bytes, Index) when Index < 0 ->
    skipWhitespace(Bytes, 0);
skipWhitespace(Bytes, Index) when Index >= byte_size(Bytes) ->
    byte_size(Bytes);
skipWhitespace(Bytes, Index) ->
    case binary:at(Bytes, Index) of
        16#20 -> skipWhitespace(Bytes, Index + 1);
        16#09 -> skipWhitespace(Bytes, Index + 1);
        16#0A -> skipWhitespace(Bytes, Index + 1);
        16#0D -> skipWhitespace(Bytes, Index + 1);
        _ -> Index
    end.
