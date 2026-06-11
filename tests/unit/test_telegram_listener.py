import sys
import os
import time
import unittest
from unittest.mock import patch, MagicMock

# Add scripts directory to path to import telegram_listener
sys.path.append(os.path.join(os.path.dirname(__file__), '../../scripts'))
import telegram_listener

class TestTelegramListener(unittest.TestCase):
    @patch('telegram_listener.make_telegram_request')
    @patch('telegram_listener.append_to_inbox')
    @patch('subprocess.run')
    @patch('time.sleep')
    @patch('time.time')
    def test_message_buffering_and_concatenation(self, mock_time, mock_sleep, mock_subprocess, mock_append, mock_request):
        # Setup environment variables
        os.environ["TELEGRAM_BOT_TOKEN"] = "123456:mock_token"
        os.environ["TELEGRAM_CHAT_ID"] = "12345"

        # Mock time sequence to simulate debounce timeout
        # 1. Start: 1000.0
        # 2. First update poll: 1000.0
        # 3. Second update poll (simulated idle): 1002.0 (1.5s passed, triggers flush)
        time_values = [1000.0, 1000.0, 1000.0, 1002.0, 1002.0, 1002.0]
        mock_time.side_effect = lambda: time_values.pop(0) if time_values else 1005.0

        # Mock request responses
        responses = [
            {"ok": True, "result": []}, # Initial getUpdates call (offset check)
            {"ok": True}, # setMyCommands call
            # Second getUpdates call (returns 2 chunked updates)
            {"ok": True, "result": [
                {
                    "update_id": 100,
                    "message": {
                        "message_id": 2001,
                        "chat": {"id": 12345},
                        "text": "Hello, this is the first chunk of a long message."
                    }
                },
                {
                    "update_id": 101,
                    "message": {
                        "message_id": 2002,
                        "chat": {"id": 12345},
                        "text": "And this is the second chunk of the message."
                    }
                }
            ]},
            # Third getUpdates call (empty updates, triggers poll timeout check and flush)
            {"ok": True, "result": []},
            # sendMessage feedback response
            {"ok": True, "result": {}}
        ]
        mock_request.side_effect = lambda token, method, payload=None: responses.pop(0) if responses else {"ok": True}

        # We want to exit the infinite loop during sleep after append_to_inbox is called
        def side_effect_sleep(*args, **kwargs):
            if mock_append.call_count > 0:
                raise KeyboardInterrupt("Stop loop")
        mock_sleep.side_effect = side_effect_sleep

        # Run main and expect it to exit with KeyboardInterrupt
        try:
            telegram_listener.main()
        except KeyboardInterrupt:
            pass

        # Verify that append_to_inbox was called with concatenated message
        mock_append.assert_called_once()
        args, _ = mock_append.call_args
        # args[0] is inbox_path
        self.assertEqual(args[1], 2001) # First message ID
        self.assertEqual(args[2], "Hello, this is the first chunk of a long message.\nAnd this is the second chunk of the message.")

        # Verify that a feedback message was sent via sendMessage
        sent_messages = [call for call in mock_request.call_args_list if call[0][1] == "sendMessage"]
        self.assertEqual(len(sent_messages), 1)
        payload = sent_messages[0][0][2]
        self.assertEqual(payload["chat_id"], "12345")
        self.assertIn("Received (Concatenated)", payload["text"])

if __name__ == '__main__':
    unittest.main()
