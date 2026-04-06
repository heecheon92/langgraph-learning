#!/bin/sh

set -eu

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

for i in 1 2 3 4 5; do
  target="module-$i/studio/.env"

  {
    printf 'OPENAI_API_KEY="%s"\n' "${OPENAI_API_KEY:-}"
    printf 'LANGSMITH_API_KEY="%s"\n' "${LANGSMITH_API_KEY:-}"
  } > "$target"
done
echo "TAVILY_API_KEY=\"$TAVILY_API_KEY\"" >> module-4/studio/.env