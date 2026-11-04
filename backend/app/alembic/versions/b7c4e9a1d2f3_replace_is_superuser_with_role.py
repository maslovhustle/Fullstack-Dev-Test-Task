"""Replace user.is_superuser with user.role

Revision ID: b7c4e9a1d2f3
Revises: fe56fa70289e
Create Date: 2026-11-03 20:30:00.000000

Backfill: is_superuser=true -> 'admin', everything else -> 'member'.
The downgrade is lossy by design: 'manager' has no equivalent in the old
boolean model, so managers become regular (non-superuser) users.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b7c4e9a1d2f3'
down_revision = 'fe56fa70289e'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        'user',
        sa.Column('role', sa.String(length=32), nullable=False, server_default='member'),
    )
    op.execute("UPDATE \"user\" SET role = 'admin' WHERE is_superuser")
    op.drop_column('user', 'is_superuser')


def downgrade():
    op.add_column(
        'user',
        sa.Column('is_superuser', sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.execute("UPDATE \"user\" SET is_superuser = (role = 'admin')")
    op.alter_column('user', 'is_superuser', server_default=None)
    op.drop_column('user', 'role')
