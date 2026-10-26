"""Telegram-style polls and quizzes for groups, channels and private chats.

A poll is attached to exactly one message (``messages.poll_id``) and keeps
its options and votes in dedicated tables so results stay consistent even
when the poll is later closed.  Nothing is hard deleted, mirroring the rest
of the project: rows are soft deleted with an auditable timestamp.
"""
from datetime import datetime
import uuid

from app import db
from app.services.timestamps import utc_iso


# Telegram bounds: 1..300 chars for the question, 2..10 options.
POLL_MAX_QUESTION = 300
POLL_MAX_OPTION = 100
POLL_MIN_OPTIONS = 2
POLL_MAX_OPTIONS = 10
POLL_MAX_EXPLANATION = 200


class Poll(db.Model):
    __tablename__ = 'polls'

    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    chat_id = db.Column(db.String(36), db.ForeignKey('chats.id'), nullable=False, index=True)
    created_by = db.Column(db.String(36), db.ForeignKey('users.id'), nullable=False, index=True)

    question = db.Column(db.String(POLL_MAX_QUESTION), nullable=False)
    # 'regular' = opinion poll, 'quiz' = one correct answer (Telegram parity).
    poll_type = db.Column(db.String(10), nullable=False, default='regular')
    is_anonymous = db.Column(db.Boolean, nullable=False, default=True)
    allows_multiple_answers = db.Column(db.Boolean, nullable=False, default=False)
    # Quiz only: explanation shown after answering.
    explanation = db.Column(db.String(POLL_MAX_EXPLANATION), nullable=True)

    is_closed = db.Column(db.Boolean, nullable=False, default=False, index=True)
    closed_at = db.Column(db.DateTime, nullable=True)
    # Optional auto-close deadline (Telegram's "close date").
    close_at = db.Column(db.DateTime, nullable=True)

    is_deleted = db.Column(db.Boolean, nullable=False, default=False, index=True)
    deleted_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    options = db.relationship(
        'PollOption', backref='poll', lazy='dynamic',
        order_by='PollOption.position',
    )

    @property
    def is_quiz(self):
        return self.poll_type == 'quiz'

    def expired(self):
        return bool(self.close_at and self.close_at <= datetime.utcnow())

    def effective_closed(self):
        return bool(self.is_closed or self.expired())


class PollOption(db.Model):
    __tablename__ = 'poll_options'

    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    poll_id = db.Column(db.String(36), db.ForeignKey('polls.id'), nullable=False, index=True)

    text = db.Column(db.String(POLL_MAX_OPTION), nullable=False)
    position = db.Column(db.Integer, nullable=False, default=0)
    # Quiz only: exactly one option carries the correct answer.
    is_correct = db.Column(db.Boolean, nullable=False, default=False)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class PollVote(db.Model):
    __tablename__ = 'poll_votes'

    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    poll_id = db.Column(db.String(36), db.ForeignKey('polls.id'), nullable=False, index=True)
    option_id = db.Column(db.String(36), db.ForeignKey('poll_options.id'), nullable=False, index=True)
    user_id = db.Column(db.String(36), db.ForeignKey('users.id'), nullable=False, index=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    __table_args__ = (
        db.UniqueConstraint('poll_id', 'option_id', 'user_id', name='uq_poll_vote'),
    )


def serialize_poll(poll, viewer_id, *, voters_limit=3):
    """Telegram-like payload: totals always, personal choices for the viewer.

    Individual voters are exposed only for public (non-anonymous) polls.
    """
    options = poll.options.all()
    option_ids = [option.id for option in options]
    votes = PollVote.query.filter(PollVote.poll_id == poll.id).all() if option_ids else []

    counts = {option_id: 0 for option_id in option_ids}
    my_option_ids = []
    voters_by_option = {option_id: [] for option_id in option_ids}
    voter_ids = set()
    for vote in votes:
        if vote.option_id in counts:
            counts[vote.option_id] += 1
            voter_ids.add(vote.user_id)
            if vote.user_id == viewer_id:
                my_option_ids.append(vote.option_id)
            if not poll.is_anonymous and len(voters_by_option[vote.option_id]) < voters_limit:
                voters_by_option[vote.option_id].append(vote.user_id)

    total_voters = len(voter_ids)
    closed = poll.effective_closed()
    answered = bool(my_option_ids)
    # Telegram hides quiz results until the viewer answers or the quiz closes.
    reveal = closed or answered or not poll.is_quiz

    voter_names = {}
    if not poll.is_anonymous:
        shown = {uid for ids in voters_by_option.values() for uid in ids}
        if shown:
            from app.models.user import User
            voter_names = {
                u.id: u.display_name
                for u in User.query.filter(User.id.in_(shown)).all()
            }

    correct_option_id = next(
        (option.id for option in options if option.is_correct), None,
    ) if poll.is_quiz else None

    return {
        'id': poll.id,
        'question': poll.question,
        'poll_type': poll.poll_type,
        'is_quiz': poll.is_quiz,
        'is_anonymous': bool(poll.is_anonymous),
        'allows_multiple_answers': bool(poll.allows_multiple_answers),
        'explanation': poll.explanation if (poll.is_quiz and (answered or closed)) else None,
        'is_closed': closed,
        'close_at': utc_iso(poll.close_at) if poll.close_at else None,
        'total_voters': total_voters,
        'has_voted': answered,
        'my_option_ids': my_option_ids,
        # The correct answer is only disclosed once the viewer answered/closed.
        'correct_option_id': correct_option_id if (answered or closed) else None,
        'is_correct': (
            correct_option_id in my_option_ids if (answered and correct_option_id) else None
        ),
        'can_close': viewer_id == poll.created_by and not closed,
        'options': [
            {
                'id': option.id,
                'text': option.text,
                'position': option.position,
                'voter_count': counts.get(option.id, 0) if reveal else 0,
                'percent': (
                    round(counts.get(option.id, 0) * 100 / total_voters)
                    if reveal and total_voters else 0
                ),
                'chosen': option.id in my_option_ids,
                'is_correct': bool(option.is_correct) if (
                    poll.is_quiz and (answered or closed)
                ) else None,
                'voters': [
                    {'id': uid, 'display_name': voter_names.get(uid, '')}
                    for uid in voters_by_option.get(option.id, [])
                ] if not poll.is_anonymous and reveal else [],
            }
            for option in options
        ],
        'created_at': utc_iso(poll.created_at),
    }
