import sys
import unittest
from unittest.mock import MagicMock, patch
import requests
import time
import os

# Ensure we can import from scripts/
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'scripts')))
import mint_gh_app_token

class TestMintNoRetry(unittest.TestCase):
    @patch('requests.post')
    @patch('time.sleep')
    def test_no_retry_on_401(self, mock_sleep, mock_post):
        # First call returns 401, should NOT retry
        mock_post.return_value = MagicMock(status_code=401)
        
        resp = mint_gh_app_token.post_with_retry("http://fake", {}, 30)
        
        self.assertEqual(resp.status_code, 401)
        self.assertEqual(mock_post.call_count, 1)
        mock_sleep.assert_not_called()
        print("MINT_NO_RETRY_ON_4XX: PASS")

if __name__ == '__main__':
    # Force output to stdout for the agent to capture
    suite = unittest.TestLoader().loadTestsFromTestCase(TestMintNoRetry)
    unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
