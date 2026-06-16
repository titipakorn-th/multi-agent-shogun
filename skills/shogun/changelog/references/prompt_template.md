# Changelog Analysis Prompt

Analyze the following raw git commits and translate them into high-signal bullets for a CHANGELOG.md file following the "Keep a Changelog" format.

## Rules:
1. Categorize changes into: ### Added, ### Changed, ### Fixed, ### Security.
2. Consolidate small or repetitive commits (e.g., multiple "typo fix" or "fmt" commits should be merged into one meaningful bullet or omitted if insignificant).
3. Use **Bold** for components or file names mentioned (e.g., **Karo**, **scripts/ntfy.sh**).
4. Do NOT include commit hashes in the final output.
5. If a commit references an Issue or PR (e.g., #123), preserve that reference.
6. The output should ONLY contain the Markdown sections (e.g., ### Added, etc.) and their bullets. Do not include a top-level date heading or version.

## Raw Commits:
{COMMITS}
