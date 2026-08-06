/** Reads the final adapter's retained NDJSON after the controller resumes. */
module final_adapter_controller;

import std.conv : to;
import std.exception : enforce;
import std.stdio : stdin;
import std.string : endsWith, startsWith;

private void expectEvent(uint expectedSequence, char expectedOctet, size_t expectedBytes)
{
    char[] line;
    enforce(stdin.readln(line) > 0, "adapter output ended before retained event");
    enum prefix = `{"subscriptionId":"retained","type":"subscription","value":{"payload":"`;
    auto suffix = `","sequence":` ~ expectedSequence.to!string ~ "}}\n";
    enforce(line.startsWith(prefix) && line.endsWith(suffix));
    enforce(line.length == prefix.length + expectedBytes + suffix.length);
    foreach (octet; line[prefix.length .. $ - suffix.length])
        enforce(octet == expectedOctet);
}

void main(string[] args)
{
    enforce(args.length == 2);
    if (args[1] == "count")
    {
        expectEvent(1, 's', 1_750_000);
        foreach (uint sequence; 3 .. 19)
            expectEvent(sequence, 's', 128 * 1024);
        return;
    }
    enforce(args[1] == "bytes");
    expectEvent(101, 'x', 1_750_000);
    foreach (uint sequence; 103 .. 106)
        expectEvent(sequence, 'x', 1_750_000);
}
