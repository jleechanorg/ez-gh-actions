import sys
import unittest
from unittest.mock import MagicMock, patch
import requests
import time
import os

# Ensure we can import from scripts/
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'scripts')))
import mint_gh_app_token

class TestMintRetry(unittest.TestCase):
    @patch('requests.post')
    @patch('time.sleep')
    def test_retry_on_connection_error(self, mock_sleep, mock_post):
        # First call raises ConnectionError, second succeeds
        mock_post.side_effect = [
            requests.exceptions.ConnectionError("boom"),
            MagicMock(status_code=201, json=lambda: {"token": "ghs_faketoken123"})
        ]
        
        resp = mint_gh_app_token.post_with_retry("http://fake", {}, 30)
        
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.json()["token"], "ghs_faketoken123")
        self.assertEqual(mock_post.call_count, 2)
        mock_sleep.assert_called_once_with(2.5)
        print("MINT_RETRY_TEST: PASS (ConnectionError)")

    @patch('requests.post')
    @patch('time.sleep')
    def test_retry_on_5xx(self, mock_sleep, mock_post):
        # First call returns 503, second succeeds
        mock_post.side_effect = [
            MagicMock(status_code=503),
            MagicMock(status_code=201, json=lambda: {"token": "ghs_faketoken123"})
        ]
        
        resp = mint_gh_app_token.post_with_retry("http://fake", {}, 30)
        
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.json()["token"], "ghs_faketoken123")
        self.assertEqual(mock_post.call_count, 2)
        mock_sleep.assert_called_once_with(2.5)
        print("MINT_RETRY_TEST: PASS (503)")

if __name__ == '__main__':
    # Force output to stdout for the agent to capture
    suite = unittest.TestLoader().loadTestsFromTestCase(TestMintRetry)
    unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
