' FreeBASIC has no standard formatter, so this deterministic style gate stands
' in for one. It is run over every checked-in .bas and .bi file in the Docker
' test stage, and it fails the build rather than reformatting, so the source
' the README and website display is exactly the source that was reviewed.

#include once "core.bi"

const STYLE_MAX_LINE = 96

dim shared as long StyleFailures

sub Complain(byref path as string, byval lineNumber as long, byref problem as string)
  StyleFailures += 1
  print "FAIL " & path & ":" & FormatInteger(lineNumber) & ": " & problem
end sub

function ReadWholeFile(byref path as string, byref contents as string) as boolean
  dim as integer handle = freefile
  if open(path for binary access read as #handle) <> 0 then
    return false
  end if
  dim as longint length = lof(handle)
  contents = ""
  if length > 0 then
    contents = space(cast(integer, length))
    get #handle, , contents
  end if
  close #handle
  return true
end function

' Track FreeBASIC string literals so a colon inside "http://" or asc(":") is
' not mistaken for a statement separator.
function HasStatementSeparator(byref textLine as string) as boolean
  dim as boolean inString = false
  dim as integer index = 0
  while index < len(textLine)
    dim as ubyte octet = textLine[index]
    if inString then
      if octet = asc("""") then
        if index + 1 < len(textLine) andalso textLine[index + 1] = asc("""") then
          index += 1
        else
          inString = false
        end if
      end if
    else
      if octet = asc("""") then
        inString = true
      elseif octet = asc("'") then
        return false
      elseif octet = asc(":") then
        return true
      end if
    end if
    index += 1
  wend
  return false
end function

sub CheckFile(byref path as string)
  dim as string contents
  if not ReadWholeFile(path, contents) then
    StyleFailures += 1
    print "FAIL " & path & ": could not be read"
    exit sub
  end if
  if not IsValidUtf8(contents) then
    Complain(path, 0, "file is not valid UTF-8")
  end if
  if len(contents) = 0 then
    Complain(path, 0, "file is empty")
    exit sub
  end if
  if contents[len(contents) - 1] <> 10 then
    Complain(path, 0, "file does not end with a newline")
  end if
  if len(contents) >= 2 andalso contents[len(contents) - 2] = 10 then
    Complain(path, 0, "file ends with a blank line")
  end if

  dim as long lineNumber = 0
  dim as integer start = 0
  dim as integer index = 0
  ' A continuation line is aligned with the construct it continues, so its
  ' indentation is deliberately not a multiple of two.
  dim as boolean continued = false
  while index <= len(contents)
    dim as boolean atEnd = (index = len(contents))
    if atEnd orelse contents[index] = 10 then
      dim as string textLine = mid(contents, start + 1, index - start)
      lineNumber += 1
      if len(textLine) > 0 andalso textLine[len(textLine) - 1] = 13 then
        Complain(path, lineNumber, "line uses a CRLF terminator")
        textLine = left(textLine, len(textLine) - 1)
      end if
      if instr(textLine, chr(9)) > 0 then
        Complain(path, lineNumber, "line contains a tab")
      end if
      if len(textLine) > STYLE_MAX_LINE then
        Complain(path, lineNumber, "line is longer than " & _
          FormatInteger(STYLE_MAX_LINE) & " columns")
      end if
      if len(textLine) > 0 andalso textLine[len(textLine) - 1] = 32 then
        Complain(path, lineNumber, "line has trailing whitespace")
      end if
      dim as long indent = 0
      while indent < len(textLine) andalso textLine[indent] = 32
        indent += 1
      wend
      if (not continued) andalso indent < len(textLine) andalso (indent mod 2) <> 0 then
        Complain(path, lineNumber, "indentation is not a multiple of two spaces")
      end if
      continued = (len(textLine) > 0 andalso textLine[len(textLine) - 1] = asc("_"))
      if HasStatementSeparator(textLine) then
        ' Several statements on one line would compress the source the README
        ' and website display verbatim.
        Complain(path, lineNumber, "line uses a colon statement separator")
      end if
      start = index + 1
    end if
    index += 1
  wend
end sub

dim as long argument = 1
dim as long inspected = 0
while len(command(argument)) > 0
  CheckFile(command(argument))
  inspected += 1
  argument += 1
wend

if inspected = 0 then
  print "FAIL style check received no files"
  end 1
end if
if StyleFailures > 0 then
  print "FAIL style check found " & FormatInteger(StyleFailures) & " problems"
  end 1
end if
print "PASS style check across " & FormatInteger(inspected) & " files"
end 0
