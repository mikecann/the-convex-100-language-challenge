#!/usr/bin/env pike
// The formatting gate for this client.
//
// Pike ships no canonical source formatter, so instead of claiming one ran,
// this test enforces the formatting rules the repository actually depends on:
// the README and the website print these files verbatim, and Pike reads source
// as single-byte characters unless a charset is declared.

array(string) pike_sources(string directory)
{
  array(string) found = ({});
  foreach (sort(get_dir(directory) || ({})), string entry) {
    string path = combine_path(directory, entry);
    if (Stdio.is_dir(path))
      found += pike_sources(path);
    else if (has_suffix(entry, ".pike"))
      found += ({ path });
  }
  return found;
}

int failures;

void complain(string path, int line, string problem)
{
  failures++;
  if (line)
    werror("FAIL %s:%d %s\n", path, line, problem);
  else
    werror("FAIL %s %s\n", path, problem);
}

void check_file(string path)
{
  string source = Stdio.read_file(path);
  if (!source) {
    complain(path, 0, "could not be read");
    return;
  }
  if (!sizeof(source) || source[-1] != '\n')
    complain(path, 0, "must end with exactly one newline");
  else if (sizeof(source) > 1 && source[-2] == '\n')
    complain(path, 0, "must not end with a blank line");

  array(string) lines = source / "\n";
  foreach (lines; int index; string line) {
    int number = index + 1;
    if (search(line, "\t") >= 0)
      complain(path, number, "uses a tab; this client indents with spaces");
    if (search(line, "\r") >= 0)
      complain(path, number, "has a carriage return");
    if (sizeof(line) > 80)
      complain(path, number,
               sprintf("is %d columns; the rendered code panel wraps past 80",
                       sizeof(line)));
    if (sizeof(line) && (line[-1] == ' ' || line[-1] == '\t'))
      complain(path, number, "has trailing whitespace");
    foreach (line / "", string character)
      if (character[0] > 126 || (character[0] < 32 && character[0] != 9)) {
        // Pike decodes source as single bytes unless the file declares a
        // charset, so a stray multi-byte character in a literal would not mean
        // what it looks like it means.
        complain(path, number, "contains a non-ASCII or control character");
        break;
      }
  }
}

int main()
{
  string root = combine_path(dirname(__FILE__), "..", "..");
  array(string) sources = pike_sources(combine_path(root, "client")) +
                          pike_sources(combine_path(root, "examples"));
  if (sizeof(sources) < 10) {
    werror("style gate found only %d Pike sources; the scan is wrong\n",
           sizeof(sources));
    return 1;
  }
  foreach (sources, string path)
    check_file(path);
  if (failures) {
    werror("style gate: %d problems in %d files\n", failures, sizeof(sources));
    return 1;
  }
  write("PASS style gate (%d Pike sources)\n", sizeof(sources));
  return 0;
}
