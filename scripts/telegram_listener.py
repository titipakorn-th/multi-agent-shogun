#!/usr/bin/env python3
import sys
import os
import time
import json
import urllib.request
import urllib.error
import subprocess

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

def get_telegram_model(script_dir):
    try:
        import yaml
        settings_path = os.path.join(script_dir, "../config/settings.yaml")
        if os.path.exists(settings_path):
            with open(settings_path, "r", encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
            model = cfg.get("cli", {}).get("agents", {}).get("telegram", {}).get("model")
            if model:
                return str(model)
    except Exception:
        pass
    return "haiku"

def make_telegram_request(token, method, payload=None):
    url = f"https://api.telegram.org/bot{token}/{method}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode('utf-8') if payload else None
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload else "GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return json.loads(res.read().decode('utf-8'))
    except Exception as e:
        return {"ok": False, "description": str(e)}

def append_to_inbox(inbox_path, msg_id, msg_text):
    import yaml
    
    entry = {
        "id": str(msg_id),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "message": msg_text,
        "status": "pending"
    }
    
    data = {"inbox": []}
    if os.path.exists(inbox_path):
        try:
            with open(inbox_path, "r", encoding="utf-8") as f:
                loaded = yaml.safe_load(f)
                if isinstance(loaded, dict) and "inbox" in loaded:
                    data = loaded
        except Exception:
            pass
            
    if not isinstance(data.get("inbox"), list):
        data["inbox"] = []
        
    data["inbox"].append(entry)
    
    # Write atomically
    temp_path = inbox_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    os.replace(temp_path, inbox_path)

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env_path = os.path.join(script_dir, "../config/telegram.env")
    env = load_env(env_path)

    token = os.environ.get("TELEGRAM_BOT_TOKEN") or env.get("TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID") or env.get("TELEGRAM_CHAT_ID")

    if not token or not chat_id or "your_bot_token_here" in token or "your_chat_id_here" in chat_id:
        print("[telegram_listener] Telegram credentials not configured. Exiting.", file=sys.stderr)
        sys.exit(1)

    print(f"[telegram_listener] Starting Telegram listener (Chat ID: {chat_id})...")

    # Register slash commands with Telegram
    commands_payload = {
        "commands": [
            {"command": "status", "description": "Get live dashboard and agent status"},
            {"command": "dashboard", "description": "Display current dashboard summary"},
            {"command": "btw", "description": "Ask a side question about the Shogun's context cheaply"},
            {"command": "help", "description": "Show usage instructions and routing help"},
            {"command": "run", "description": "Run a side task command in workspace shell"}
        ]
    }
    register_res = make_telegram_request(token, "setMyCommands", commands_payload)
    if register_res.get("ok"):
        print("[telegram_listener] Successfully registered slash commands with Telegram.")
    else:
        print(f"[telegram_listener] Warning: Failed to register slash commands: {register_res.get('description')}")

    # Get current offset (only process messages sent after listener startup)
    updates_res = make_telegram_request(token, "getUpdates", {"limit": 1})
    offset = 0
    if updates_res.get("ok") and updates_res.get("result"):
        offset = updates_res["result"][-1]["update_id"] + 1

    inbox_path = os.path.join(script_dir, "../queue/ntfy_inbox.yaml")

    while True:
        try:
            poll_payload = {
                "offset": offset,
                "timeout": 30,
                "allowed_updates": ["message", "callback_query"]
            }
            poll_res = make_telegram_request(token, "getUpdates", poll_payload)

            if not poll_res.get("ok"):
                time.sleep(5)
                continue

            for update in poll_res.get("result", []):
                offset = update["update_id"] + 1
                
                # Check if there is an active telegram question
                question_file = os.path.join(script_dir, "../queue/current_question.json")
                active_question = None
                if os.path.exists(question_file):
                    try:
                        with open(question_file, "r", encoding="utf-8") as qf:
                            active_question = json.load(qf)
                    except Exception:
                        pass
                
                # A. Handle Callback Query (Button taps on Telegram dialogs)
                if "callback_query" in update:
                    cb = update["callback_query"]
                    cb_msg = cb.get("message", {})
                    cb_chat_id = cb_msg.get("chat", {}).get("id")
                    
                    if str(cb_chat_id) != str(chat_id):
                        continue
                        
                    if active_question and active_question.get("status") != "answered" and cb_msg.get("message_id") == active_question.get("message_id"):
                        data = cb.get("data", "")
                        
                        if data == "opt_other":
                            # Acknowledge callback query
                            make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": "Please type your response."})
                            
                            # Edit original message to remove buttons and prompt for text input
                            new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✏️ *Please type your custom reply below:*"
                            make_telegram_request(token, "editMessageText", {
                                "chat_id": chat_id,
                                "message_id": active_question.get("message_id"),
                                "text": new_text,
                                "parse_mode": "Markdown"
                            })
                            
                            # Update JSON to waiting_for_free_text
                            active_question["status"] = "waiting_for_free_text"
                            try:
                                with open(question_file, "w", encoding="utf-8") as qf:
                                    json.dump(active_question, qf, indent=2, ensure_ascii=False)
                            except Exception:
                                pass
                                
                        elif data.startswith("opt_"):
                            try:
                                opt_idx = int(data.split("_")[1])
                                selected_option = active_question.get("options", [])[opt_idx]
                            except Exception:
                                selected_option = data
                                
                            # Acknowledge callback query
                            make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": f"Selected: {selected_option}"})
                            
                            # Edit original message to show selection
                            new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✅ *Selected:* {selected_option}"
                            make_telegram_request(token, "editMessageText", {
                                "chat_id": chat_id,
                                "message_id": active_question.get("message_id"),
                                "text": new_text,
                                "parse_mode": "Markdown"
                            })
                            
                            # Update JSON to answered
                            active_question["status"] = "answered"
                            active_question["response"] = selected_option
                            try:
                                with open(question_file, "w", encoding="utf-8") as qf:
                                    json.dump(active_question, qf, indent=2, ensure_ascii=False)
                            except Exception:
                                pass
                    continue
                
                # B. Handle Messages
                if "message" in update:
                    msg = update["message"]
                    msg_chat_id = msg.get("chat", {}).get("id")
                    
                    if str(msg_chat_id) != str(chat_id):
                        continue
                        
                    # Check if this message is a reply/answer to the active question
                    is_reply_to_question = False
                    reply_to = msg.get("reply_to_message", {})
                    if active_question and active_question.get("status") != "answered":
                        is_reply = reply_to.get("message_id") == active_question.get("message_id")
                        is_waiting = active_question.get("status") == "waiting_for_free_text"
                        if is_reply or is_waiting:
                            is_reply_to_question = True
                            
                    if is_reply_to_question:
                        reply_text = msg.get("text", "").strip()
                        if reply_text:
                            # Confirm receipt by editing the original message to show the reply
                            new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✅ *Reply:* {reply_text}"
                            make_telegram_request(token, "editMessageText", {
                                "chat_id": chat_id,
                                "message_id": active_question.get("message_id"),
                                "text": new_text,
                                "parse_mode": "Markdown"
                            })
                            
                            # Update JSON to answered
                            active_question["status"] = "answered"
                            active_question["response"] = reply_text
                            try:
                                with open(question_file, "w", encoding="utf-8") as qf:
                                    json.dump(active_question, qf, indent=2, ensure_ascii=False)
                            except Exception:
                                pass
                        continue
                        
                    # Ignore replies (handled by reply check above)
                    if "reply_to_message" in msg:
                        continue
                        
                    msg_text = msg.get("text", "").strip()
                    if not msg_text:
                        continue
                        
                    msg_id = msg.get("message_id")
                    print(f"[telegram_listener] Received command: {msg_text}")
                    
                    # Check if it is a slash command or status/dashboard/help/btw keywords
                    lower_msg = msg_text.lower()
                    if msg_text.startswith("/") or lower_msg in ["status", "status?", "dashboard", "help", "btw"] or lower_msg.startswith("btw "):
                        print(f"[telegram_listener] Routing side command to Telegram agent: {msg_text}")
                        # Signal Telegram agent to wake up
                        inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                        subprocess.run([
                            "bash", inbox_write_path, "telegram",
                            msg_text,
                            "telegram_cmd", "telegram_listener"
                        ], check=True)
                    else:
                        print(f"[telegram_listener] Forwarding to Shogun: {msg_text}")
                        # Write to the inbox file
                        append_to_inbox(inbox_path, msg_id, msg_text)
                        
                        # Signal Shogun to wake up
                        inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                        subprocess.run([
                            "bash", inbox_write_path, "shogun",
                            f"Received new command from Telegram: {msg_text}",
                            "ntfy_received", "telegram_listener"
                        ], check=True)
                    
            time.sleep(1)
        except Exception as e:
            print(f"[telegram_listener] Error: {e}", file=sys.stderr)
            time.sleep(5)

if __name__ == "__main__":
    main()
