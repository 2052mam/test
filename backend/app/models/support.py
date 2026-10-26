"""Support tickets raised from the login / verification screens (Point 6).

A user who cannot receive their SMS code is, by definition, not signed in, so
the normal in-app support chat is unreachable. These rows are the unauthenticated
escape hatch: the admin panel reads them in its Support inbox and can answer by
phone, or link the ticket to the user's support chat once they get in.
"""
import uuid
from datetime import datetime

from app import db
from app.services.timestamps import utc_iso

TICKET_STATUSES = ('open', 'in_progress', 'resolved', 'closed')
TICKET_TOPICS = (
    'code_not_received',
    'login_problem',
    'account_locked',
    'bug_report',
    'abuse',
    'other',
)


class SupportTicket(db.Model):
    __tablename__ = 'support_tickets'

    id = db.Column(db.String(36), primary_key=True,
                   default=lambda: str(uuid.uuid4()))

    # Filled when the reporter happens to be signed in; NULL for the
    # login-screen flow, which is exactly the case this table exists for.
    user_id = db.Column(db.String(36), db.ForeignKey('users.id'),
                        nullable=True, index=True)

    mobile_number = db.Column(db.String(16), nullable=True, index=True)
    display_name = db.Column(db.String(150), nullable=True)
    topic = db.Column(db.String(40), nullable=False, default='other',
                      index=True)
    message = db.Column(db.Text, nullable=False)

    status = db.Column(db.String(20), nullable=False, default='open',
                       index=True)
    admin_note = db.Column(db.Text, nullable=True)
    assigned_to = db.Column(db.String(36), nullable=True, index=True)
    resolved_by = db.Column(db.String(36), nullable=True)
    resolved_at = db.Column(db.DateTime, nullable=True)

    ip_address = db.Column(db.String(45), nullable=True)
    user_agent = db.Column(db.Text, nullable=True)
    app_version = db.Column(db.String(50), nullable=True)
    platform = db.Column(db.String(40), nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False,
                           index=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow,
                           onupdate=datetime.utcnow, nullable=False)

    def to_dict(self, include_contact=True):
        data = {
            'id': self.id,
            'user_id': self.user_id,
            'display_name': self.display_name,
            'topic': self.topic,
            'message': self.message,
            'status': self.status,
            'admin_note': self.admin_note,
            'assigned_to': self.assigned_to,
            'resolved_by': self.resolved_by,
            'resolved_at': utc_iso(self.resolved_at) if self.resolved_at else None,
            'app_version': self.app_version,
            'platform': self.platform,
            'created_at': utc_iso(self.created_at),
            'updated_at': utc_iso(self.updated_at),
        }
        if include_contact:
            data.update({
                'mobile_number': self.mobile_number,
                'ip_address': self.ip_address,
                'user_agent': self.user_agent,
            })
        return data


class SecurityAlert(db.Model):
    """An account-security event the owner must see immediately (Point 3).

    Login attempts from a new device are written here the moment they happen,
    so the chat list can surface a banner on its very next poll instead of
    waiting for a push tick or for the user to open Saved Messages.
    """
    __tablename__ = 'security_alerts'

    id = db.Column(db.String(36), primary_key=True,
                   default=lambda: str(uuid.uuid4()))
    user_id = db.Column(db.String(36), db.ForeignKey('users.id'),
                        nullable=False, index=True)
    device_id = db.Column(db.String(36), nullable=True, index=True)

    # new_device_login | login_code_requested | device_terminated |
    # two_factor_enabled | two_factor_disabled | password_changed
    alert_type = db.Column(db.String(40), nullable=False, index=True)
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.Text, nullable=True)
    severity = db.Column(db.String(20), nullable=False, default='warning')

    device_name = db.Column(db.String(150), nullable=True)
    device_model = db.Column(db.String(150), nullable=True)
    ip_address = db.Column(db.String(45), nullable=True)

    is_read = db.Column(db.Boolean, nullable=False, default=False,
                        server_default=db.false(), index=True)
    read_at = db.Column(db.DateTime, nullable=True)
    is_dismissed = db.Column(db.Boolean, nullable=False, default=False,
                             server_default=db.false())

    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False,
                           index=True)

    __table_args__ = (
        db.Index('idx_security_alert_feed', 'user_id', 'is_dismissed',
                 'created_at'),
    )

    def to_dict(self):
        return {
            'id': self.id,
            'alert_type': self.alert_type,
            'title': self.title,
            'body': self.body,
            'severity': self.severity,
            'device_id': self.device_id,
            'device_name': self.device_name,
            'device_model': self.device_model,
            'ip_address': self.ip_address,
            'is_read': bool(self.is_read),
            'created_at': utc_iso(self.created_at),
        }
