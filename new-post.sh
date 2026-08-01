#!/usr/bin/env bash
# new-post.sh "Post Title" [tag1 tag2 ...]
# Creates src/content/posts/YYYY-MM-DD-slug.md from the title.
set -euo pipefail

title="${1:?usage: new-post.sh \"Post Title\" [tags...]}"
tags="${*:2}"

slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
date=$(date +%Y-%m-%d)
file="src/content/posts/${date}-${slug}.md"

if [ -e "$file" ]; then
  echo "exists: $file" >&2
  exit 1
fi

{
  echo "---"
  echo "title: \"$title\""
  echo "date: $date"
  if [ -n "$tags" ]; then
    echo "tags: [$(echo "$tags" | sed 's/ /, /g')]"
  else
    echo "tags: []"
  fi
  echo "---"
  echo
  echo "What I worked on:"
  echo
  echo "- "
  echo
  echo "What broke / what I didn't expect:"
  echo
  echo "- "
  echo
  echo "What I learned:"
  echo
  echo "- "
  echo
  echo "Next:"
  echo
  echo "- "
} > "$file"

echo "created $file"
