package convex.tests

/** Small deterministic Groovy teaching-source lint used by the Docker test gate. */
final class StyleCheck {
  static final int MAX_LINE_LENGTH = 120

  static void main(String[] roots) {
    List<File> sources = roots.collectMany { String root ->
      sourceFiles(new File(root))
    }
    assert !sources.isEmpty(): 'style checker found no Groovy sources'
    sources.each { File source -> check(source) }
    println "PASS Groovy style lint (${sources.size()} source files)"
  }

  private static List<File> sourceFiles(File file) {
    if (file.isFile()) {
      return file.name.endsWith('.groovy') ? [file] : []
    }
    (file.listFiles() ?: []).toList().sort { it.name }.collectMany {
      sourceFiles(it)
    }
  }

  private static void check(File source) {
    String text = source.getText('UTF-8')
    assert text.endsWith('\n'): "${source} must end with a newline"
    text.readLines().eachWithIndex { String line, int index ->
      int number = index + 1
      assert !line.contains('\t'): "${source}:${number} contains a tab"
      assert line == line.stripTrailing(): "${source}:${number} has trailing whitespace"
      assert line.length() <= MAX_LINE_LENGTH:
        "${source}:${number} exceeds ${MAX_LINE_LENGTH} columns"
      String code = line
      int comment = code.indexOf('//')
      if (comment >= 0) {
        code = code.substring(0, comment)
      }
      String trimmed = code.trim()
      boolean syntaxNeedsSeparator = trimmed.startsWith('for (') ||
        trimmed.startsWith('try (')
      boolean prose = trimmed.startsWith('*') || trimmed.startsWith('/**')
      if (!syntaxNeedsSeparator && !prose) {
        assert code.indexOf(59) < 0:
          "${source}:${number} compresses multiple statements with a semicolon"
      }
    }
  }
}
