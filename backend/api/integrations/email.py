"""SES email integration - skeleton.

Fill in with real templates/verification once the product needs email.
"""

from __future__ import annotations

import boto3

from api.config import get_settings
from api.core.logging import get_logger

logger = get_logger("email")


def send_email(to: str, subject: str, body: str) -> None:
    settings = get_settings()
    client = boto3.client("ses", region_name=settings.region)
    client.send_email(
        Source=settings.email_from,
        Destination={"ToAddresses": [to]},
        Message={
            "Subject": {"Data": subject},
            "Body": {"Text": {"Data": body}},
        },
    )
    logger.info("email sent to %s: %s", to, subject)
