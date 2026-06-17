from django.contrib.auth import login, get_user_model
from django.shortcuts import redirect


class AutheliaMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        remote_user = request.META.get('HTTP_REMOTE_USER')

        if remote_user:
            User = get_user_model()
            user, created = User.objects.get_or_create(
                username=remote_user,
                defaults={
                    'is_staff': remote_user in ['admin', 'root'],
                    'is_superuser': remote_user in ['admin', 'root'],
                }
            )
            if created:
                user.set_unusable_password()
                user.save()

            if '_auth_user_id' not in request.session or request.session.get('_auth_user_id') != user.pk:
                request.session.cycle_key()
                request.backend = 'django.contrib.auth.backends.ModelBackend'
                login(request, user)

        # Force password change if admin still uses default password
        if (request.user.is_authenticated
                and request.session.get('force_password_change')
                and request.path not in ('/change-password/', '/logout/')):
            return redirect('/change-password/')

        response = self.get_response(request)
        return response
