"""Template context processors for the DB-free WebUI."""


def user(request):
    # Expose request.user to templates the same way the removed
    # django.contrib.auth context processor used to.
    return {'user': request.user}
