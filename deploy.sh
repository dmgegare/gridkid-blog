#!/bin/bash
set -euo pipefail

# ── PATHS ────────────────────────────────────────────────────────────────────
OBSIDIAN_POSTS="/Users/$(whoami)/Documents/Obsidian Notes/2 - Areas/Blog"
OBSIDIAN_ATTACHMENTS="/Users/$(whoami)/Documents/Obsidian Notes/2 - Areas/Blog/attachments"
HUGO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUGO_POSTS="$HUGO_ROOT/content/posts"
HUGO_IMAGES="$HUGO_ROOT/static/images"
DEPLOY_USER="dgegare"
DEPLOY_HOST="192.168.0.80"
DEPLOY_PATH="/opt/appdata/blog/public/"
export OBSIDIAN_ATTACHMENTS HUGO_POSTS HUGO_IMAGES

# ── CHECKS ───────────────────────────────────────────────────────────────────
echo "// Grid Kid Deploy Script"
echo "── Checking dependencies..."

for cmd in git rsync python3 hugo; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed or not in PATH."
    exit 1
  fi
done

# ── SYNC POSTS ───────────────────────────────────────────────────────────────
echo "── Syncing posts from Obsidian..."

mkdir -p "$HUGO_POSTS"
mkdir -p "$HUGO_IMAGES"

# Copy only non-draft markdown files
# A file is considered non-draft if it contains "draft: false" in frontmatter
# or has no draft field at all
for file in "$OBSIDIAN_POSTS"/*.md; do
  [ -f "$file" ] || continue
  filename=$(basename "$file")

  # Skip files with draft: true
  if grep -q "^draft: true" "$file"; then
    echo "   Skipping draft: $filename"
    continue
  fi

  echo "   Copying: $filename"
  cp "$file" "$HUGO_POSTS/$filename"
done

# ── PROCESS IMAGES ───────────────────────────────────────────────────────────
echo "── Processing images..."

python3 << 'PYTHON'
import os
import re
import shutil

posts_dir  = os.environ["HUGO_POSTS"]
attach_dir = os.environ["OBSIDIAN_ATTACHMENTS"]
images_dir = os.environ["HUGO_IMAGES"]

os.makedirs(images_dir, exist_ok=True)

for filename in os.listdir(posts_dir):
    if not filename.endswith(".md"):
        continue

    filepath = os.path.join(posts_dir, filename)

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    # Find all Obsidian wiki-style image links: ![[image.png]] or [[image.png]]
    images = re.findall(r'!\[\[([^\]]+\.(png|jpg|jpeg|gif|webp|svg))\]\]', content, re.IGNORECASE)

    for image_match in images:
        image_name = image_match[0]
        # Build Hugo-compatible markdown image link
        safe_name = image_name.replace(" ", "%20")
        markdown_image = f"![{image_name}](/images/{safe_name})"
        # Replace Obsidian syntax with Hugo syntax
        content = content.replace(f"![[{image_name}]]", markdown_image)

        # Copy image to Hugo static/images
        src = os.path.join(attach_dir, image_name)
        dst = os.path.join(images_dir, image_name)
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"   Copied image: {image_name}")
        else:
            print(f"   Warning: image not found: {image_name}")

    # Write updated content back
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

print("   Image processing complete.")
PYTHON

# ── BUILD ────────────────────────────────────────────────────────────────────
echo "── Building Hugo site..."
cd "$HUGO_ROOT"
hugo build --minify

# ── DEPLOY ───────────────────────────────────────────────────────────────────
echo "── Deploying to server..."
rsync -avz --delete public/ "$DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH"

# ── GIT ──────────────────────────────────────────────────────────────────────
echo "── Pushing to GitHub..."
cd "$HUGO_ROOT"
git add .
git commit -m "deploy: $(date '+%Y-%m-%d %H:%M')" || echo "   Nothing to commit."
git push

echo ""
echo "// Deploy complete. Site is live at https://gegare.com"
