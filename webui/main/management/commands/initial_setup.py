import subprocess
import os
from pathlib import Path
from django.core.management.base import BaseCommand
from django.contrib.auth.models import User


class Command(BaseCommand):
    help = "Create initial admin user"

    def handle(self, *args, **options):
        if not User.objects.filter(username="admin").exists():
            User.objects.create_superuser("admin", "admin@local", "admin")
            self.stdout.write(self.style.SUCCESS("Admin user created."))
        else:
            self.stdout.write("Admin user already exists.")
