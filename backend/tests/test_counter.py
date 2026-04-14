"""
test_counter.py — Unit tests for the visitor counter Lambda handler.

Run with:
    cd backend
    pip install pytest boto3
    pytest tests/ -v

All AWS calls are mocked — no live AWS resources or credentials required.
"""

import json
import os
import sys
import importlib
from unittest.mock import MagicMock, patch

import pytest

# ── Environment setup ─────────────────────────────────────────────────────────
# Must be set before the module under test is imported, because app.py reads
# TABLE_NAME at module level when boto3.resource('dynamodb').Table() is called.
os.environ['TABLE_NAME'] = 'test-table'
os.environ['CORS_ORIGIN'] = 'https://www.example.com'


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def mock_dynamodb():
    """
    Patches boto3.resource so no real AWS calls are made.
    Returns a configured mock table that simulates a successful update_item
    response with count=42.
    """
    with patch('boto3.resource') as mock_resource:
        mock_dynamodb_resource = MagicMock()
        mock_resource.return_value = mock_dynamodb_resource

        mock_table = MagicMock()
        mock_dynamodb_resource.Table.return_value = mock_table

        mock_table.update_item.return_value = {
            'Attributes': {'count': 42}
        }

        # Re-import app fresh so it picks up the patched boto3
        if 'counter_function.app' in sys.modules:
            del sys.modules['counter_function.app']
        if 'app' in sys.modules:
            del sys.modules['app']

        yield mock_table


@pytest.fixture
def get_event():
    """Minimal API Gateway proxy event for a GET /counter request."""
    return {
        'httpMethod': 'GET',
        'path': '/counter',
        'headers': {},
        'queryStringParameters': None,
        'body': None,
    }


@pytest.fixture
def options_event():
    """API Gateway proxy event for a CORS preflight OPTIONS request."""
    return {
        'httpMethod': 'OPTIONS',
        'path': '/counter',
        'headers': {
            'Origin': 'https://www.example.com',
            'Access-Control-Request-Method': 'GET',
        },
        'queryStringParameters': None,
        'body': None,
    }


# ── Helper ────────────────────────────────────────────────────────────────────

def get_handler():
    """Import and return the lambda_handler after mocks are in place."""
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
    import counter_function.app as app_module
    return app_module.lambda_handler


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestStatusCode:

    def test_returns_200_on_success(self, mock_dynamodb, get_event):
        handler = get_handler()
        result = handler(get_event, {})
        assert result['statusCode'] == 200

    def test_returns_200_for_options_preflight(self, mock_dynamodb, options_event):
        handler = get_handler()
        result = handler(options_event, {})
        assert result['statusCode'] == 200


class TestResponseBody:

    def test_body_contains_count_key(self, mock_dynamodb, get_event):
        handler = get_handler()
        result = handler(get_event, {})
        body = json.loads(result['body'])
        assert 'count' in body

    def test_count_matches_dynamodb_return_value(self, mock_dynamodb, get_event):
        handler = get_handler()
        result = handler(get_event, {})
        body = json.loads(result['body'])
        assert body['count'] == 42

    def test_options_body_is_empty_or_valid_json(self, mock_dynamodb, options_event):
        handler = get_handler()
        result = handler(options_event, {})
        # Body should be empty string or parseable JSON
        assert result['body'] == '' or json.loads(result['body']) is not None


class TestDynamoDBInteraction:

    def test_calls_update_item_once(self, mock_dynamodb, get_event):
        handler = get_handler()
        handler(get_event, {})
        mock_dynamodb.update_item.assert_called_once()

    def test_uses_add_for_atomic_increment(self, mock_dynamodb, get_event):
        handler = get_handler()
        handler(get_event, {})
        call_kwargs = mock_dynamodb.update_item.call_args.kwargs
        assert 'ADD' in call_kwargs['UpdateExpression']

    def test_targets_correct_counter_id(self, mock_dynamodb, get_event):
        handler = get_handler()
        handler(get_event, {})
        call_kwargs = mock_dynamodb.update_item.call_args.kwargs
        assert call_kwargs['Key'] == {'id': 'visitor_count'}

    def test_uses_expression_attribute_names_for_reserved_word(self, mock_dynamodb, get_event):
        """'count' is a DynamoDB reserved word and must use ExpressionAttributeNames."""
        handler = get_handler()
        handler(get_event, {})
        call_kwargs = mock_dynamodb.update_item.call_args.kwargs
        assert '#count' in call_kwargs['ExpressionAttributeNames'].values() \
               or 'count' in call_kwargs['ExpressionAttributeNames'].values()

    def test_options_request_does_not_call_dynamodb(self, mock_dynamodb, options_event):
        """Preflight requests must not touch DynamoDB."""
        handler = get_handler()
        handler(options_event, {})
        mock_dynamodb.update_item.assert_not_called()


class TestCorsHeaders:

    def test_response_includes_cors_allow_origin(self, mock_dynamodb, get_event):
        handler = get_handler()
        result = handler(get_event, {})
        assert 'Access-Control-Allow-Origin' in result['headers']

    def test_cors_origin_matches_environment_variable(self, mock_dynamodb, get_event):
        handler = get_handler()
        result = handler(get_event, {})
        assert result['headers']['Access-Control-Allow-Origin'] == 'https://www.example.com'

    def test_options_response_includes_cors_headers(self, mock_dynamodb, options_event):
        handler = get_handler()
        result = handler(options_event, {})
        assert 'Access-Control-Allow-Origin' in result['headers']


class TestErrorHandling:

    def test_returns_500_on_dynamodb_client_error(self, mock_dynamodb, get_event):
        from botocore.exceptions import ClientError
        mock_dynamodb.update_item.side_effect = ClientError(
            {'Error': {'Code': 'ProvisionedThroughputExceededException', 'Message': 'Test'}},
            'UpdateItem'
        )
        handler = get_handler()
        result = handler(get_event, {})
        assert result['statusCode'] == 500

    def test_returns_500_on_unexpected_error(self, mock_dynamodb, get_event):
        mock_dynamodb.update_item.side_effect = RuntimeError('Unexpected')
        handler = get_handler()
        result = handler(get_event, {})
        assert result['statusCode'] == 500

    def test_error_body_contains_error_key(self, mock_dynamodb, get_event):
        mock_dynamodb.update_item.side_effect = RuntimeError('Unexpected')
        handler = get_handler()
        result = handler(get_event, {})
        body = json.loads(result['body'])
        assert 'error' in body
