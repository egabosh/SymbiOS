import os
from django.core.management.base import BaseCommand
from django.contrib.auth.models import User


class Command(BaseCommand):
    help = 'Erstellt initialen Admin-Benutzer beim ersten Start'

    def handle(self, *args, **options):
        if User.objects.filter(is_superuser=True).exists():
            return

        admin_user = os.environ.get('SYMBIOS_ADMIN_USER', 'admin')
        admin_password = os.environ.get('SYMBIOS_ADMIN_PASSWORD', 'admin')

        if not User.objects.filter(username=admin_user).exists():
            User.objects.create_superuser(admin_user, f'{admin_user}@symbios.local', admin_password)
            self.stdout.write(self.style.SUCCESS(f'Admin "{admin_user}" erstellt.'))
        else:
            self.stdout.write(self.style.WARNING(f'Admin "{admin_user}" existiert bereits.'))
