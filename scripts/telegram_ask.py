#!/usr/bin/env python3
import sys
import os
import argparse
import time
import json
import urllib.request
import urllib.error

def load_env(env_path):
    env_vars = {}
    if os.path.exists(env_path):
        with open(env_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, val = line.split('=', 1)
                    env_vars[key.strip()] = val.strip()
    return env_vars

def make_telegram_request(token, method, payload=None):
    url = f"https://api.telegram.org/bot{token}/{method}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode('utf-8') if payload else None
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload else "GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return json.loads(res.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode('utf-8')
        try:
            err_json = json.loads(err_msg)
            return {"ok": False, "description": err_json.get("description", str(e))}
        except Exception:
            return {"ok": False, "description": f"HTTP Error {e.code}: {e.reason}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}

def main():
    parser = argparse.ArgumentParser(description="Ask the user a question via Telegram and block until answered.")
    parser.add_argument("--question", required=True, help="The question text to ask.")
    parser.add_argument("--options", nargs="+", help="Multiple-choice options. If omitted, waits for a text reply.")
    parser.add_argument("--timeout", type=int, default=3600, help="Timeout in seconds (default: 3600).")
    args = parser.parse_args()

    # Load credentials
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env_path = os.path.join(script_dir, "../config/telegram.env")
    env = load_env(env_path)

    token = os.environ.get("TELEGRAM_BOT_TOKEN") or env.get("TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID") or env.get("TELEGRAM_CHAT_ID")

    if not token or not chat_id or "your_bot_token_here" in token or "your_chat_id_here" in chat_id:
        print("ERROR: Telegram credentials not configured. Please create config/telegram.env or set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.", file=sys.stderr)
        sys.exit(1)

    # Write to current_question.json for Shogun panel feedback
    question_file = os.path.join(script_dir, "../queue/current_question.json")
    question_data = {
        "question": args.question,
        "options": args.options or [],
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "status": "pending"
    }
    try:
        with open(question_file, "w", encoding="utf-8") as f:
            json.dump(question_data, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"WARNING: Failed to write to {question_file}: {e}", file=sys.stderr)

    def cleanup_question_file():
        try:
            if os.path.exists(question_file):
                os.remove(question_file)
        except Exception:
            pass

    # 1. Send the question
    payload = {
        "chat_id": chat_id,
        "text": f"❓ *Question:*\n{args.question}",
        "parse_mode": "Markdown"
    }

    if args.options:
        keyboard = []
        for idx, opt in enumerate(args.options):
            keyboard.append([{"text": opt, "callback_data": f"opt_{idx}"}])
        # Append "Other (free text)" option as the last choice
        keyboard.append([{"text": "✏️ Other (free text)", "callback_data": "opt_other"}])
        payload["reply_markup"] = {"inline_keyboard": keyboard}

    send_res = make_telegram_request(token, "sendMessage", payload)
    if not send_res.get("ok"):
        print(f"ERROR: Failed to send message to Telegram: {send_res.get('description')}", file=sys.stderr)
        cleanup_question_file()
        sys.exit(1)

    sent_message_id = send_res["result"]["message_id"]
    
    # Update current_question.json with sent_message_id
    question_data["message_id"] = sent_message_id
    try:
        with open(question_file, "w", encoding="utf-8") as f:
            json.dump(question_data, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"WARNING: Failed to update {question_file}: {e}", file=sys.stderr)

    start_time = time.time()

    # 2. Watch for the answer from the file (updated by the always-on listener daemon)
    try:
        while True:
            if time.time() - start_time > args.timeout:
                print("ERROR: Timeout waiting for user response on Telegram.", file=sys.stderr)
                sys.exit(1)

            if os.path.exists(question_file):
                try:
                    with open(question_file, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    if data.get("status") == "answered":
                        print(data.get("response", ""))
                        sys.exit(0)
                except Exception:
                    pass
            time.sleep(0.5)

    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(1)
    finally:
        cleanup_question_file()

if __name__ == "__main__":
    main()
