import pytest
from unittest import mock

def test_sample():
    with mock.patch('builtins.print') as mock_print:
        print('hello')
        mock_print.assert_called_with('hello')
