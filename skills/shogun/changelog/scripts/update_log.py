import os
import re
import subprocess
import sys

def get_latest_date_from_file(filepath):
    """
    Extracts the ISO date (YYYY-MM-DD) from the first heading of the form:
    ## [VERSION] - YYYY-MM-DD
    """
    if not os.path.exists(filepath):
        return None
        
    # Pattern to match: ## [ANYTHING] - YYYY-MM-DD
    date_pattern = re.compile(r'^##\s+\[.*\]\s+-\s+(\d{4}-\d{2}-\d{2})')
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                match = date_pattern.match(line.strip())
                if match:
                    return match.group(1)
    except Exception as e:
        print(f"Error reading {filepath}: {e}", file=sys.stderr)
        
    return None

def get_commits_since(date):
    """
    Fetches git commits since the given date.
    Returns a list of strings in the format "hash|subject".
    """
    command = [
        "git", "log",
        f"--after={date}",
        "--pretty=format:%h|%s",
        "--no-merges"
    ]
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        if result.stdout:
            return result.stdout.strip().split('\n')
        return []
    except subprocess.CalledProcessError as e:
        print(f"Git error: {e.stderr}", file=sys.stderr)
        return []
    except Exception as e:
        print(f"Error running git: {e}", file=sys.stderr)
        return []

def prepare_prompt(commits, template_path):
    """
    Reads the template from template_path, replaces {COMMITS} with 
    the newline-separated raw commits, and returns the final prompt.
    """
    try:
        with open(template_path, 'r', encoding='utf-8') as f:
            template = f.read()
        
        commits_str = "\n".join(commits)
        return template.replace("{COMMITS}", commits_str)
    except Exception as e:
        print(f"Error preparing prompt: {e}", file=sys.stderr)
        return None

def update_changelog(filepath, new_content):
    """
    Reads the existing content of filepath, finds the # Changelog title,
    and prepends new_content after it.
    """
    if not os.path.exists(filepath):
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write("# Changelog\n\n" + new_content.strip() + "\n")
        return

    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    header_index = -1
    for i, line in enumerate(lines):
        if line.strip().startswith("# Changelog"):
            header_index = i
            break

    # Strip new_content to handle it cleanly
    new_content = new_content.strip()

    if header_index != -1:
        # Insert after header
        insert_pos = header_index + 1
        lines.insert(insert_pos, "\n" + new_content + "\n")
    else:
        # Prepend to top
        lines.insert(0, new_content + "\n\n")

    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(lines)

if __name__ == "__main__":
    # Example usage
    changelog_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../CHANGELOG.md"))
    latest_date = get_latest_date_from_file(changelog_path)
    if latest_date:
        print(f"Latest date: {latest_date}")
        commits = get_commits_since(latest_date)
        for commit in commits:
            print(commit)
    else:
        print("No date found.")
