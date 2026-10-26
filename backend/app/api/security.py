"""Instant account-security feed for the chat list (Point 3).

The Flutter chat list polls this endpoint alongside its normal refresh, so a
login attempt from another device is on screen within one poll interval rather
than whenever a push tick happens to arrive.
"""
from datetime import datetime

from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt, get_jwt_identity, jwt_required

from app import db
from app.models.support import SecurityAlert
from app.services.security_alerts import is_primary_device, primary_device
from app.services.timestamps import utc_iso

security_bp = Blueprint('security', __name__)


@security_bp.route('/alerts', methods=['GET'])
@jwt_required()
def list_alerts():
    """Live alerts for the banner, newest first."""
    user_id = get_jwt_identity()
    try:
        limit = max(1, min(int(request.args.get('limit', 20)), 50))
    except (TypeError, ValueError):
        return jsonify({'error': 'limit نامعتبر است'}), 400
    unread_only = request.args.get('unread') in ('1', 'true', 'True')

    query = SecurityAlert.query.filter_by(
        user_id=user_id, is_dismissed=False)
    if unread_only:
        query = query.filter_by(is_read=False)
    alerts = query.order_by(SecurityAlert.created_at.desc()).limit(limit).all()

    unread = SecurityAlert.query.filter_by(
        user_id=user_id, is_dismissed=False, is_read=False).count()
    owner = primary_device(user_id)
    return jsonify({
        'alerts': [a.to_dict() for a in alerts],
        'unread': unread,
        'server_time': utc_iso(datetime.utcnow()),
        'is_primary_device': is_primary_device(
            user_id, get_jwt().get('device_id')),
        'primary_device_id': owner.id if owner else None,
    }), 200


@security_bp.route('/alerts/<alert_id>/read', methods=['POST'])
@jwt_required()
def mark_read(alert_id):
    user_id = get_jwt_identity()
    alert = SecurityAlert.query.filter_by(
        id=alert_id, user_id=user_id).first()
    if not alert:
        return jsonify({'error': 'هشدار یافت نشد'}), 404
    alert.is_read = True
    alert.read_at = datetime.utcnow()
    db.session.commit()
    return jsonify({'ok': True}), 200


@security_bp.route('/alerts/<alert_id>/dismiss', methods=['POST'])
@jwt_required()
def dismiss(alert_id):
    user_id = get_jwt_identity()
    alert = SecurityAlert.query.filter_by(
        id=alert_id, user_id=user_id).first()
    if not alert:
        return jsonify({'error': 'هشدار یافت نشد'}), 404
    alert.is_dismissed = True
    alert.is_read = True
    alert.read_at = alert.read_at or datetime.utcnow()
    db.session.commit()
    return jsonify({'ok': True}), 200


@security_bp.route('/alerts/read-all', methods=['POST'])
@jwt_required()
def read_all():
    user_id = get_jwt_identity()
    SecurityAlert.query.filter_by(
        user_id=user_id, is_read=False,
    ).update(
        {'is_read': True, 'read_at': datetime.utcnow()},
        synchronize_session=False,
    )
    db.session.commit()
    return jsonify({'ok': True}), 200
