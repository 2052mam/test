"""Telegram-parity polls and quizzes."""
from datetime import datetime, timedelta

from app import db
from app.models.poll import Poll


def create_poll(client, auth, user='alice', **overrides):
    body = {
        'chat_id': 'chat',
        'question': 'Best editor?',
        'options': [{'text': 'Vim'}, {'text': 'Emacs'}],
    }
    body.update(overrides)
    return client.post('/api/v1/polls/', headers=auth(user), json=body)


def test_creating_a_poll_posts_a_message_with_the_poll_payload(client, auth):
    result = create_poll(client, auth)
    assert result.status_code == 201
    assert result.json['message_type'] == 'poll'
    poll = result.json['poll']
    assert poll['question'] == 'Best editor?'
    assert [option['text'] for option in poll['options']] == ['Vim', 'Emacs']
    assert poll['total_voters'] == 0 and poll['has_voted'] is False

    history = client.get('/api/v1/messages/chat', headers=auth('bob')).json['messages']
    assert history[-1]['poll']['id'] == poll['id']


def test_poll_needs_two_distinct_options_and_a_question(client, auth):
    assert create_poll(client, auth, question=' ').status_code == 400
    assert create_poll(client, auth, options=[{'text': 'only'}]).status_code == 400
    assert create_poll(client, auth, options=[{'text': f'o{i}'} for i in range(11)]).status_code == 400


def test_outsider_cannot_create_or_read_a_poll(client, auth):
    assert create_poll(client, auth, user='carol').status_code == 403
    poll_id = create_poll(client, auth).json['poll']['id']
    assert client.get(f'/api/v1/polls/{poll_id}', headers=auth('carol')).status_code == 403
    assert client.post(f'/api/v1/polls/{poll_id}/vote', headers=auth('carol'),
                       json={'option_id': 'x'}).status_code == 403


def test_single_choice_vote_switches_and_retracts(client, auth):
    poll = create_poll(client, auth).json['poll']
    first, second = [option['id'] for option in poll['options']]

    voted = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                        json={'option_id': first}).json
    assert voted['total_voters'] == 1 and voted['my_option_ids'] == [first]
    assert voted['options'][0]['percent'] == 100

    switched = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                           json={'option_id': second}).json
    assert switched['my_option_ids'] == [second] and switched['total_voters'] == 1

    # Tapping the same option again retracts it, exactly like Telegram.
    retracted = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                            json={'option_id': second}).json
    assert retracted['my_option_ids'] == [] and retracted['total_voters'] == 0


def test_multiple_answers_poll_accepts_several_options(client, auth):
    poll = create_poll(client, auth, allows_multiple_answers=True).json['poll']
    ids = [option['id'] for option in poll['options']]
    result = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                         json={'option_ids': ids}).json
    assert sorted(result['my_option_ids']) == sorted(ids)
    assert result['total_voters'] == 1

    single = create_poll(client, auth).json['poll']
    rejected = client.post(f'/api/v1/polls/{single["id"]}/vote', headers=auth('bob'),
                           json={'option_ids': [o['id'] for o in single['options']]})
    assert rejected.status_code == 400


def test_quiz_reveals_the_answer_only_after_answering_and_is_final(client, auth):
    created = create_poll(
        client, auth, poll_type='quiz', question='2 + 2 = ?',
        options=[{'text': '3'}, {'text': '4'}, {'text': '5'}, {'text': '6'}],
        correct_option_index=1, explanation='Basic arithmetic',
    )
    assert created.status_code == 201
    poll = created.json['poll']
    assert poll['is_quiz'] is True and poll['correct_option_id'] is None
    assert poll['explanation'] is None

    options = [option['id'] for option in poll['options']]
    wrong = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                        json={'option_id': options[0]}).json
    assert wrong['correct_option_id'] == options[1]
    assert wrong['is_correct'] is False
    assert wrong['explanation'] == 'Basic arithmetic'

    # A quiz answer can never be changed or retracted.
    assert client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                       json={'option_id': options[1]}).status_code == 409
    assert client.post(f'/api/v1/polls/{poll["id"]}/retract', headers=auth('bob')).status_code == 409


def test_quiz_requires_exactly_one_correct_option(client, auth):
    assert create_poll(client, auth, poll_type='quiz',
                       options=[{'text': 'a'}, {'text': 'b'}]).status_code == 400
    assert create_poll(client, auth, poll_type='quiz',
                       options=[{'text': 'a', 'is_correct': True},
                                {'text': 'b', 'is_correct': True}]).status_code == 400


def test_closing_a_poll_stops_voting_and_only_the_author_may_close(client, auth):
    poll = create_poll(client, auth).json['poll']
    assert client.post(f'/api/v1/polls/{poll["id"]}/close', headers=auth('bob')).status_code == 403
    closed = client.post(f'/api/v1/polls/{poll["id"]}/close', headers=auth())
    assert closed.status_code == 200 and closed.json['is_closed'] is True
    blocked = client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                          json={'option_id': poll['options'][0]['id']})
    assert blocked.status_code == 409


def test_expired_close_date_closes_the_poll(app, client, auth):
    poll = create_poll(client, auth).json['poll']
    with app.app_context():
        row = db.session.get(Poll, poll['id'])
        row.close_at = datetime.utcnow() - timedelta(minutes=1)
        db.session.commit()
    assert client.get(f'/api/v1/polls/{poll["id"]}', headers=auth()).json['is_closed'] is True


def test_public_poll_exposes_voters_but_anonymous_does_not(client, auth):
    public = create_poll(client, auth, is_anonymous=False).json['poll']
    option = public['options'][0]['id']
    client.post(f'/api/v1/polls/{public["id"]}/vote', headers=auth('bob'),
                json={'option_id': option})
    voters = client.get(f'/api/v1/polls/{public["id"]}/voters', headers=auth())
    assert voters.status_code == 200
    assert voters.json['options'][0]['voters'][0]['id'] == 'bob'

    private = create_poll(client, auth).json['poll']
    assert client.get(f'/api/v1/polls/{private["id"]}/voters', headers=auth()).status_code == 403


def test_send_message_endpoint_refuses_raw_poll_messages(client, auth):
    result = client.post('/api/v1/messages/', headers=auth(), json={
        'chat_id': 'chat', 'message_type': 'poll', 'content': 'hi',
    })
    assert result.status_code == 400


def test_forwarding_a_poll_copies_it_with_a_fresh_tally(client, auth):
    created = create_poll(client, auth)
    message_id = created.json['id']
    poll = created.json['poll']
    client.post(f'/api/v1/polls/{poll["id"]}/vote', headers=auth('bob'),
                json={'option_id': poll['options'][0]['id']})

    forwarded = client.post(f'/api/v1/messages/{message_id}/forward', headers=auth(),
                            json={'target_chat_id': 'other'})
    assert forwarded.status_code == 201
    history = client.get('/api/v1/messages/other', headers=auth()).json['messages']
    copy = history[-1]['poll']
    assert copy['id'] != poll['id']
    assert copy['question'] == poll['question']
    assert copy['total_voters'] == 0
