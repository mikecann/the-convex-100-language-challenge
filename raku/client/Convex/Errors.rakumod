unit module Convex::Errors;

# Keeping error classes structured lets the adapter preserve the distinction
# between a Convex function rejection, malformed protocol data, and a failure
# to reach the deployment. The shared conformance controller checks
# `error.data.code` for a function rejection, so the structured payload has to
# survive all the way from the deployment response to the NDJSON event.
#
# These classes are exported because callers pattern-match them inside CATCH
# blocks. Without `is export` the only visible name would be the fully
# qualified `Convex::Errors::X::Convex::Function`, which reads badly in a
# `when` clause.

class X::Convex::Function is Exception is export {
    has Str $.message-text is required;
    has Str $.operation is required;
    # `$.data` stays an undecorated JSON value: the deployment owns its shape
    # and the adapter forwards it verbatim.
    has $.data;
    has @.logs;

    method message() {
        "Convex {$!operation} failed: {$!message-text}"
    }
}

class X::Convex::Protocol is Exception is export {
    has Str $.detail is required;

    method message() {
        "Convex protocol error: {$!detail}"
    }
}

class X::Convex::Transport is Exception is export {
    has Str $.detail is required;
    has Str $.operation = 'transport';

    method message() {
        "Convex {$!operation} transport error: {$!detail}"
    }
}

class X::Convex::Closed is Exception is export {
    method message() {
        'Convex client is closed'
    }
}
