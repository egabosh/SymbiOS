"""
Network configuration forms with IP validation.
"""
import os
import ipaddress
from pathlib import Path
from typing import Dict, Any
from django import forms
from django.core.exceptions import ValidationError

CONFIG_FILE = Path("/config/settings_network.conf")


class NetworkConfigForm(forms.Form):
    use_dhcp = forms.BooleanField(
        label="Use DHCP",
        required=False,
        initial=False,
        widget=forms.CheckboxInput(attrs={'class': 'form-check-input'})
    )
    
    ip_address = forms.CharField(
        label="IPv4 Address",
        max_length=15,
        required=False,
        widget=forms.TextInput(attrs={'class': 'form-control'})
    )
    
    subnet_mask = forms.CharField(
        label="Subnet Mask",
        max_length=15,
        required=False,
        widget=forms.TextInput(attrs={'class': 'form-control'})
    )
    
    gateway = forms.CharField(
        label="Gateway",
        max_length=15,
        required=False,
        widget=forms.TextInput(attrs={'class': 'form-control'})
    )
    
    dns1 = forms.CharField(
        label="DNS Server",
        max_length=15,
        required=False,
        widget=forms.TextInput(attrs={'class': 'form-control'})
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.load_current_config()

    def load_current_config(self):
        """Load current values from config file if exists."""
        if not CONFIG_FILE.exists():
            return
            
        try:
            with open(CONFIG_FILE, 'r') as f:
                for line in f:
                    key, value = line.strip().split('=', 1)
                    key = key.strip()
                    value = value.strip().strip('"')
                    
                    if key == 'use_dhcp' and value.lower() == 'true':
                        self.initial['use_dhcp'] = True
                    elif key in ['ip_address', 'subnet_mask', 'gateway', 'dns1']:
                        self.initial[key] = value
                        
        except Exception:
            pass  # Silently ignore config read errors

    def clean_ip_address(self):
        ip = self.cleaned_data.get('ip_address')
        if ip:
            try:
                ipaddress.IPv4Address(ip)
            except ipaddress.AddressValueError:
                raise ValidationError("Invalid IPv4 address format.")
        return ip

    def clean_subnet_mask(self):
        mask = self.cleaned_data.get('subnet_mask')
        if mask:
            try:
                # Accept both CIDR (/24) and dotted decimal (255.255.255.0)
                if mask.startswith('/'):
                    ipaddress.IPv4Network(f"0.0.0.0{mask}", strict=False)
                else:
                    ipaddress.IPv4Address(mask)
            except ipaddress.AddressValueError:
                raise ValidationError("Invalid subnet mask (use /24 or 255.255.255.0).")
        return mask

    def clean_gateway(self):
        gateway = self.cleaned_data.get('gateway')
        if gateway:
            try:
                ipaddress.IPv4Address(gateway)
            except ipaddress.AddressValueError:
                raise ValidationError("Invalid IPv4 address format.")
        return gateway

    def clean_dns1(self):
        dns = self.cleaned_data.get('dns1')
        if dns:
            try:
                ipaddress.IPv4Address(dns)
            except ipaddress.AddressValueError:
                raise ValidationError("Invalid IPv4 address format.")
        return dns

    def clean(self):
        cleaned_data = super().clean()
        use_dhcp = cleaned_data.get('use_dhcp')
        
        # If DHCP is enabled, all static fields must be empty
        if use_dhcp:
            for field in ['ip_address', 'subnet_mask', 'gateway', 'dns1']:
                if cleaned_data.get(field):
                    raise ValidationError(f"{field.replace('_', ' ').title()} must be empty when using DHCP.")
        else:
            # If DHCP disabled, IP, mask and gateway are required
            required_fields = ['ip_address', 'subnet_mask', 'gateway']
            for field in required_fields:
                if not cleaned_data.get(field):
                    raise ValidationError(f"{field.replace('_', ' ').title()} is required for static configuration.")
                    
        return cleaned_data

    def save(self):
        """Write configuration to file."""
        config_lines = []
        
        if self.cleaned_data['use_dhcp']:
            config_lines.append('use_dhcp=true')
        else:
            config_lines.extend([
                f"use_dhcp=false",
                f'ip_address="{self.cleaned_data["ip_address"]}"',
                f'subnet_mask="{self.cleaned_data["subnet_mask"]}"',
                f'gateway="{self.cleaned_data["gateway"]}"',
                f'dns1="{self.cleaned_data["dns1"]}"',
            ])
        
        try:
            with open(CONFIG_FILE, 'w') as f:
                f.write('\n'.join(config_lines) + '\n')
            return True
        except Exception:
            raise ValidationError("Failed to write configuration file.")

