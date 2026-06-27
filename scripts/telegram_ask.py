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
    parser.add_argument("--no-wait", action="store_true", help="Send the question and exit immediately without waiting for a response.")
    parser.add_argument("--no-other", action="store_true", help="Do not append the 'Other (free text)' option to multiple-choice questions.")
    parser.add_argument("--info", action="store_true", help="Send as an informational message. Exits immediately, does not write to current_question.json, and does not block.")
    parser.add_argument("--tag", help="Compact source tag prepended to the question text, e.g. 'orchestrator · cmd_104'. Informational only; keeps the Lord oriented when several questions arrive in a session. (plan 2026-06-27-telegram-bidirectional-ask-assessment.md Task 1)")
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

    question_file = os.path.join(script_dir, "../queue/current_question.json")

    def cleanup_question_file():
        if not args.info:
            try:
                if os.path.exists(question_file):
                    os.remove(question_file)
            except Exception:
                pass

    # 1. Send the question
    # Optional source tag: "[source · cmd_xxx] " prefix on the question so
    # the Lord can identify which agent/cmd a decision is for when several
    # questions stack up. Plain "❓ Question:" header is preserved so the
    # parser-recognized prefix remains unchanged.
    body = args.question
    if args.tag:
        body = f"[{args.tag}] {body}"
    payload = {
        "chat_id": chat_id,
        "text": f"❓ *Question:*\n{body}" if not args.info else f"ℹ️ *Notice:*\n{body}",
        "parse_mode": "Markdown"
    }

    if args.options:
        keyboard = []
        for idx, opt in enumerate(args.options):
            keyboard.append([{"text": opt, "callback_data": f"opt_{idx}"}])
        # Append "Other (free text)" option as the last choice unless suppressed or informational
        if not args.no_other and not args.info:
            keyboard.append([{"text": "✏️ Other (free text)", "callback_data": "opt_other"}])
        payload["reply_markup"] = {"inline_keyboard": keyboard}

    send_res = make_telegram_request(token, "sendMessage", payload)
    if not send_res.get("ok"):
        print(f"ERROR: Failed to send message to Telegram: {send_res.get('description')}", file=sys.stderr)
        cleanup_question_file()
        sys.exit(1)

    sent_message_id = send_res["result"]["message_id"]

    # ponytail: write current_question.json EXACTLY ONCE, AFTER Telegram
    # returns message_id. The previous two-write sequence opened a race:
    # the listener could load the no-message-id intermediate write, then
    # fail to match callback_query.message_id against active_question.message_id
    # (None), silently dropping Lord's button taps and never marking the
    # question answered.
    if not args.info:
        question_data = {
            "question": args.question,
            "options": args.options or [],
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "status": "pending",
            "message_id": sent_message_id,
        }
        try:
            with open(question_file, "w", encoding="utf-8") as f:
                json.dump(question_data, f, indent=2, ensure_ascii=False)
        except Exception as e:
            print(f"WARNING: Failed to write to {question_file}: {e}", file=sys.stderr)

    if args.info or args.no_wait:
        if args.info:
            print(f"Informational message sent. Message ID: {sent_message_id}")
        else:
            print(f"Question sent asynchronously. Message ID: {sent_message_id}")
        sys.exit(0)

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
