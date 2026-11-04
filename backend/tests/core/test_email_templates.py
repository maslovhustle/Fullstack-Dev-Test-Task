from app.utils import generate_new_account_email, generate_reset_password_email


def test_new_account_email_escapes_user_values() -> None:
    email = generate_new_account_email(
        email_to="user@example.com",
        username="user@example.com",
        password="<script>alert('x')</script>&",
    )

    assert "<script>" not in email.html_content
    assert "&lt;script&gt;" in email.html_content


def test_reset_email_keeps_the_token_link_intact() -> None:
    email = generate_reset_password_email(
        email_to="user@example.com", email="user@example.com", token="abc.def-ghi_jkl"
    )

    assert "reset-password?token=abc.def-ghi_jkl" in email.html_content
