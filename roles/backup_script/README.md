# backup_script Ansible Role

This role deploys and manages a robust backup automation system, including:
- Backup scripts and config
- Systemd user service/timer
- msmtp email config
- Sudoers for btrfs commands
- Idempotent, safe to rerun, and robust error handling

## Role Variables
See `defaults/main.yml` for all variables and their defaults.

## Usage Example
```yaml
- hosts: backup_servers
  become: true
  roles:
    - role: backup_script
      vars:
        backup_user: backup
        msmtp_host: smtp.example.com
        msmtp_user: backup@example.com
        msmtp_password: "supersecret"
```

## Files to Provide
- Place your backup-main.sh, zfs-snap.py, and backup-main.conf in the `files/` directory before running.

## Idempotency
- All tasks are safe to rerun and will not overwrite existing config unless changed.
- Sudoers and systemd units are validated before applying.

## Error Handling
- Fails on error with clear messages.
- Systemd and sudoers changes are validated.

## Requirements
- Ansible >= 2.9
- Target system: Linux with systemd, btrfs, msmtp
