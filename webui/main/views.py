from django.shortcuts import render
from .forms import NetworkConfigForm
from .utils.log_utils import logs_stream

def settings(request):
    return render(request, 'main/settings.html')

def settings_network(request):
    if request.method == 'POST':
        form = NetworkConfigForm(request.POST)
        if form.is_valid():
            try:
                form.save()
                form.add_error(None, "Configuration saved successfully!")
            except Exception as e:
                form.add_error(None, f"Save failed: {str(e)}")
    else:
        form = NetworkConfigForm()
    
    context = {
        "form": form,
        "full_width": False,  # Keep sidebar for settings
    }
    return render(request, 'main/settings_network.html', context)

def settings_ddns(request):
    return render(request, 'main/settings_ddns.html')

def settings_auth(request):
    return render(request, 'main/settings_auth.html')

def logs(request):
    context = {
        "default_log_name": "symbios",
    }
    return render(request, 'main/logs.html', context)

def users_groups(request):
    return render(request, 'main/users_groups.html')

