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

def get_system_language(script_dir):
    try:
        import yaml
        settings_path = os.path.join(script_dir, "../config/settings.yaml")
        if os.path.exists(settings_path):
            with open(settings_path, "r", encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("language", "en")
    except Exception:
        pass
    return "en"

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
    message_buffers = {}

    while True:
        try:
            # Determine timeout based on whether any buffers have chunks
            has_buffered = any(len(buf["chunks"]) > 0 for buf in message_buffers.values())
            poll_timeout = 1 if has_buffered else 30

            poll_payload = {
                "offset": offset,
                "timeout": poll_timeout,
                "allowed_updates": ["message", "callback_query"]
            }
            poll_res = make_telegram_request(token, "getUpdates", poll_payload)

            if poll_res.get("ok"):
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
                                
                                # Wake up Karo via inbox
                                try:
                                    inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                                    subprocess.run([
                                        "bash", inbox_write_path, "karo",
                                        f"Telegram question answered: {selected_option}",
                                        "telegram_answer", "telegram_listener"
                                    ], check=True)
                                except Exception as e:
                                    print(f"[telegram_listener] Error nudging Karo: {e}", file=sys.stderr)
                        else:
                            # Clear loading spinner for informational callback queries
                            make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": "Acknowledged"})
                            
                            # Remove inline keyboard from the informational message
                            make_telegram_request(token, "editMessageReplyMarkup", {
                                "chat_id": chat_id,
                                "message_id": cb_msg.get("message_id"),
                                "reply_markup": {"inline_keyboard": []}
                            })
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
                                
                                # Wake up Karo via inbox
                                try:
                                    inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                                    subprocess.run([
                                        "bash", inbox_write_path, "karo",
                                        f"Telegram question answered: {reply_text}",
                                        "telegram_answer", "telegram_listener"
                                    ], check=True)
                                except Exception as e:
                                    print(f"[telegram_listener] Error nudging Karo: {e}", file=sys.stderr)
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
                        if lower_msg == "/help" or lower_msg == "help":
                            help_text = (
                                "🏯 *multi-agent-shogun Command Help* ⚔️\n\n"
                                "You can control your Shogun AI team directly from this chat.\n\n"
                                "*Slash Commands:*\n"
                                "• `/status` - Query the live status of all active agent panes.\n"
                                "• `/dashboard` - Show a summary of the current project tasks.\n"
                                "• `/help` - Display this help guide.\n\n"
                                "*How to order your Shogun:*\n"
                                "Simply send any natural language command here. Shogun will receive it, decompose it, and delegate it to the Karo and Ashigaru workers in the background.\n\n"
                                "Example:\n"
                                "`Implement a user authentication endpoint in python`"
                            )
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": help_text,
                                "parse_mode": "Markdown"
                            })
                            print(f"[telegram_listener] sendMessage (/help) response: {res}")
                            continue

                        if msg_text.startswith("/") or lower_msg in ["status", "status?", "dashboard", "btw"] or lower_msg.startswith("btw "):
                            print(f"[telegram_listener] Routing side command to Telegram agent: {msg_text}")
                            # Signal Telegram agent to wake up
                            inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                            subprocess.run([
                                "bash", inbox_write_path, "telegram",
                                msg_text,
                                "telegram_cmd", "telegram_listener"
                            ], check=True)
                        else:
                            print(f"[telegram_listener] Buffering normal command/message: {msg_text}")
                            cid_str = str(chat_id)
                            if cid_str not in message_buffers:
                                message_buffers[cid_str] = {
                                    "last_received": time.time(),
                                    "chunks": []
                                }
                            message_buffers[cid_str]["chunks"].append({
                                "id": msg_id,
                                "text": msg_text
                            })
                            message_buffers[cid_str]["last_received"] = time.time()
            else:
                time.sleep(2)

            # Flush expired buffers
            current_time = time.time()
            chats_to_flush = []
            for cid, buf in message_buffers.items():
                if buf["chunks"] and (current_time - buf["last_received"] >= 1.5):
                    chats_to_flush.append(cid)

            for cid in chats_to_flush:
                buf = message_buffers[cid]
                # Sort chunks by message ID to ensure correct order
                sorted_chunks = sorted(buf["chunks"], key=lambda x: x["id"])
                concatenated_text = "\n".join(chunk["text"] for chunk in sorted_chunks)
                first_msg_id = sorted_chunks[0]["id"]

                print(f"[telegram_listener] Flushing buffer for chat {cid}. Concatenated text length: {len(concatenated_text)}")

                # Forward to Shogun
                append_to_inbox(inbox_path, first_msg_id, concatenated_text)

                # Send instant feedback to user
                msg_preview = concatenated_text
                if len(msg_preview) > 60:
                    msg_preview = msg_preview[:60] + "..."

                lang = get_system_language(script_dir)
                if lang == "ja":
                    feedback_text = f"📱 *受信 (結合):* \"{msg_preview}\"\n\n🏯 *将軍:* ハッ、承知いたしました。ただちに将軍に伝達し、指示を分析中..."
                else:
                    feedback_text = f"📱 *Received (Concatenated):* \"{msg_preview}\"\n\n🏯 *Shogun:* Ha! (Yes!) Conveying directive to Shogun. Analyzing..."

                make_telegram_request(token, "sendMessage", {
                    "chat_id": cid,
                    "text": feedback_text,
                    "parse_mode": "Markdown"
                })

                # Signal Shogun to wake up
                inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                try:
                    subprocess.run([
                        "bash", inbox_write_path, "shogun",
                        f"Received new command from Telegram: {concatenated_text}",
                        "ntfy_received", "telegram_listener"
                    ], check=True)
                except Exception as e:
                    print(f"[telegram_listener] Error nudging Shogun: {e}", file=sys.stderr)

                # Clear buffer for this chat
                message_buffers[cid]["chunks"] = []

            time.sleep(0.5)
        except Exception as e:
            print(f"[telegram_listener] Error: {e}", file=sys.stderr)
            time.sleep(5)

if __name__ == "__main__":
    main()
