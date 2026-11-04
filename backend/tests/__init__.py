# Runs before conftest imports any app module, so the engine is created
# for the dedicated test database (see tests/utils/database.py).
from tests.utils.database import use_test_database

use_test_database()
