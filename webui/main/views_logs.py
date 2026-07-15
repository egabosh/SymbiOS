from django.shortcuts import render
from .decorators import login_required
from django.http import JsonResponse
from .utils.log_utils import logs_stream


@login_required
def logs(request):
    response = render(request, 'main/logs.html', {'default_log_name': 'messages'})
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response
