# Copyright (c) 2026, Oliver Bohlen
"""HTTP utility helpers for views."""


def is_ajax_request(request):
    """Return True if the request is an AJAX (XMLHttpRequest) call."""
    return request.headers.get('X-Requested-With') == 'XMLHttpRequest'
