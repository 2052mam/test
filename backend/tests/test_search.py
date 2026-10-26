"""Global search must find joined groups, not only public channels."""
from app import db
from app.models.chat import Chat, ChatMember


def make_chat(app, chat_id, title, chat_type='group', public=False, members=('alice',)):
    with app.app_context():
        db.session.add(Chat(
            id=chat_id, chat_type=chat_type, title=title,
            created_by='alice', is_public=public,
        ))
        db.session.flush()
        for name in members:
            db.session.add(ChatMember(chat_id=chat_id, user_id=name))
        db.session.commit()


def search(client, auth, term, user='alice'):
    return client.get(f'/api/v1/users/search?q={term}', headers=auth(user)).json


def test_search_finds_a_group_the_user_belongs_to(app, client, auth):
    make_chat(app, 'g1', 'Flutter Developers')
    found = search(client, auth, 'flutter')['chats']
    assert [c['id'] for c in found] == ['g1']
    assert found[0]['chat_type'] == 'group'
    assert found[0]['is_member'] is True


def test_search_finds_private_groups_and_channels_by_membership(app, client, auth):
    make_chat(app, 'g2', 'Secret Team', public=False)
    make_chat(app, 'c2', 'Secret Channel', chat_type='channel', public=False)
    ids = {c['id'] for c in search(client, auth, 'secret')['chats']}
    assert ids == {'g2', 'c2'}
    # A non-member must not see private chats they are not part of.
    assert search(client, auth, 'secret', user='bob')['chats'] == []


def test_public_channels_and_groups_stay_discoverable_for_non_members(app, client, auth):
    make_chat(app, 'c3', 'Public News', chat_type='channel', public=True)
    make_chat(app, 'g3', 'Public Lounge', chat_type='group', public=True)
    found = search(client, auth, 'public', user='bob')['chats']
    assert {c['id'] for c in found} == {'c3', 'g3'}
    assert all(c['is_member'] is False for c in found)


def test_joined_chats_are_listed_before_suggestions(app, client, auth):
    make_chat(app, 'g4', 'Design public', members=('alice',))
    make_chat(app, 'c4', 'Design public channel', chat_type='channel',
              public=True, members=('bob',))
    found = search(client, auth, 'design')['chats']
    assert found[0]['id'] == 'g4' and found[0]['is_member'] is True
    assert found[1]['id'] == 'c4'


def test_deleted_chats_never_appear(app, client, auth):
    make_chat(app, 'g5', 'Gone Group')
    with app.app_context():
        db.session.get(Chat, 'g5').is_deleted = True
        db.session.commit()
    assert search(client, auth, 'gone')['chats'] == []
