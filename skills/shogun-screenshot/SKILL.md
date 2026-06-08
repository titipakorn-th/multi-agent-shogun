---
name: shogun-screenshot
description: |
  Captures and processes screenshots. Retrieves the latest image from local screenshots,
  captures web pages via Playwright, crops/resizes images, and masks sensitive info in black.
  Triggered during article writing, report generation, UI verification, or image processing.
  Triggered by: "screenshot", "screen capture", "latest screenshot", "crop image", "mask image", "capture screen".
  Do NOT use for: Image generation (use the shogun-imagegen skill instead).
argument-hint: "[url-or-target e.g. https://example.com, latest]"
allowed-tools: Bash, Read
---

# /shogun-screenshot - Screenshot Capture & Processing Skill

## North Star (Supreme standard for all judgments)

The North Star of this skill is **content differentiation through visual quality enhancement of articles and reports**.
By inserting high-quality images (masked and properly cropped) into articles and reports, we achieve differentiation from competitor content that relies on text alone.

## Input

$ARGUMENTS = Specification of the target operation (URL or mode keyword)

- URL (https://...) → Mode 2: Web Capture
- latest (optional) → Mode 1: Local Screenshot Retrieval
- No arguments → Select the optimal mode based on the user's intent

## Overview

Captures and processes screenshots. Supports four modes:

1. **Local Retrieval**: Get the latest image from the user's screenshot folder
2. **Web Capture**: Capture a page by specifying a URL via Playwright MCP
3. **Cropping**: Crop and resize part of an existing image
4. **Masking**: Black out sensitive info (API keys, personal data, etc.)

## When to Use

- When asked to "show the latest screenshot" or "take a screenshot"
- When inserting images into articles or reports
- When UI screen captures are required
- When image cropping or cutting is required
- When masking confidential info within screenshots

## Configuration

The paths to the screenshot folders are managed in `config/settings.yaml` (ordered list of preference):

```yaml
screenshot:
  paths:
    - "/path/to/your/Screenshots/"      # OS screenshot save location
    - "queue/screenshots/"               # Received location from mobile apps, etc.
  capture_dir: "images/"                 # Save location for Web captures
  trim_dir: "images/trimmed/"            # Save location for cropped images
```

Searches the `paths` array in order, using the first directory that exists and contains image files.
Returns an error if none of the paths exist.

## Instructions

### Mode 1: Local Screenshot Retrieval (Multiple Path Fallback)

**Steps**:
1. Read the `screenshot.paths` array from `config/settings.yaml`
2. **Search each path in order of priority**:
   a. Confirm directory existence with `ls <path>` (if not exists, move to the next)
   b. In the existing path, get the latest images using `ls -lt <path>/*.png <path>/*.jpg 2>/dev/null | head -5`
3. Display the newest image file using the view_file tool
4. If images exist in multiple paths, compare the latest from all paths and display the newest one

**Helper script** (automatically searches all paths):
```bash
bash skills/shogun-screenshot/scripts/capture_local.sh -n 3
```

**When specifying a specific path manually**:
```bash
# Uses the path configured in screenshot.paths of config/settings.yaml
ls -lt "/path/to/Screenshots/"*.png 2>/dev/null | head -3
```

**Note**: The directory itself might not exist (e.g. drive not mounted).
Suppress errors from non-existent paths with `2>/dev/null`.

### Mode 2: Web Capture (Playwright MCP)

1. Navigate to the URL using Playwright MCP's `playwright_navigate`
2. Capture the screenshot using `playwright_screenshot`
   - fullPage: true (entire page)
   - selector: specified (element only)
   - savePng: true, downloadsDir: save destination
3. Return the path of the saved PNG

### Mode 3: Cropping

1. Receive the path of the target image
2. Execute cropping with Python (PIL/Pillow)
3. Save the cropped image

```bash
python3 skills/shogun-screenshot/scripts/trim_image.py \
  --input /path/to/image.png \
  --output /path/to/trimmed.png \
  --crop "x1,y1,x2,y2"
```

Option: `--resize "width,height"` can perform resizing simultaneously.

### Mode 4: Sensitive Info Masking

Blacks out API keys, topic names, personal info, etc., in the screenshot with rectangles.

```bash
# Single region
python3 skills/shogun-screenshot/scripts/mask_sensitive.py \
  --input /path/to/image.png \
  --output /path/to/masked.png \
  --regions "100,50,400,80"

# Multiple regions
python3 skills/shogun-screenshot/scripts/mask_sensitive.py \
  --input /path/to/image.png \
  --output /path/to/masked.png \
  --regions "100,50,400,80" "500,200,800,230"

# Position verification (Red outline preview, no blackout)
python3 skills/shogun-screenshot/scripts/mask_sensitive.py \
  --input /path/to/image.png \
  --output /path/to/preview.png \
  --regions "100,50,400,80" --preview
```

Options:
- `--color "R,G,B"` — Blackout color (default: black `0,0,0`)
- `--preview` — Red outline preview only (no blackout. For coordinate verification)

**Steps**:
1. View the image with the view_file tool and identify the regions to mask
2. Verify if coordinates are correct with `--preview`
3. If the preview is OK, run without `--preview`

## Guidelines

- Avoid including API keys or credentials in images. Always mask them with Mode 4 before publishing.
- If Playwright MCP is unavailable, run only in local mode.
- Use batch processing scripts when processing a large volume of screenshots at once.
- Cropping/masking coordinates are pixel values based on the top-left (0,0) origin.
- Default save destination: project's `images/` directory
