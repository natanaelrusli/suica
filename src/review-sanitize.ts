// MARK: - Sanitising for GitLab

/** Applies `change` to the parts of a line outside inline code spans. */
function outsideInlineCode(line: string, change: (text: string) => string): string {
  return line
    .split("`")
    .map((part, index) => (index % 2 === 0 ? change(part) : part))
    .join("`");
}

function stripMentionsAndLinks(text: string): string {
  return (
    text
      // [label](url) keeps its label; <url> and bare URLs go.
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/<https?:\/\/[^>\s]*>/g, "(link removed)")
      .replace(/\bhttps?:\/\/[^\s)>\]]+/g, "(link removed)")
      // @user and @group/sub notify people; an email address (word before @) is left alone.
      .replace(/(^|[^\w@])@(?=[\w.-]*\w)/g, "$1")
  );
}

/**
 * Makes model output safe to post as the Owner: outside code, a line starting with `/` is escaped
 * so GitLab does not run it as a quick action, @mentions are removed so nobody is notified, and
 * links are removed. GitLab ignores quick actions and mentions inside code, so code stays as written.
 */
export function sanitizeForGitLab(markdown: string): string {
  let inFence = false;
  return markdown
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) return line;
      const escaped = line.replace(/^(\s*)\//, "$1\\/");
      return outsideInlineCode(escaped, stripMentionsAndLinks);
    })
    .join("\n");
}
