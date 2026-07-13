from django.shortcuts import render
from .decorators import login_required
from django.http import JsonResponse
from .utils.log_utils import logs_stream


@login_required
def logs(request):
    return render(request, 'main/logs.html', {'default_log_name': 'messages'})
