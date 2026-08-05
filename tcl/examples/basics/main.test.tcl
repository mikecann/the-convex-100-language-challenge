#!/usr/local/bin/tclsh
# Focused regression for values that would otherwise produce a misleading
# universal happy-path transcript. It sources the exact canonical example.
source [file normalize [file join [file dirname [info script]] main.tcl]]
set zero {{"count":0.0}}
set one {{"count":1.0}}
if {[whole_count $zero test] != 0 || [whole_count $one test] != 1} { error "whole JSON floats were not normalized" }
foreach raw {{{"count":0.5}} {{"count":"1"}} {{"count":Inf}}} {
    if {![catch {whole_count $raw test}]} { error "invalid count $raw was accepted" }
}
puts "Tcl example number tests passed"
