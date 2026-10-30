"""Private order API. Cosmos resources are provisioned only by infrastructure."""

import os
import threading
import time
from contextlib import asynccontextmanager, suppress
from datetime import UTC, datetime
from uuid import UUID

from common import (
    Catalog,
    Health,
    OrderRequest,
    Product,
    Receipt,
    configure_telemetry,
    dependency_event,
    protect,
)
from fastapi import FastAPI, HTTPException
from starlette.concurrency import run_in_threadpool

CATALOG = [
    {
        "id": "field-kit",
        "category": "equipment",
        "name": "Field operations kit",
        "description": "A synthetic commissioning kit for distributed teams.",
        "price_cents": 12900,
    },
    {
        "id": "sensor-pack",
        "category": "equipment",
        "name": "Precision sensor pack",
        "description": "A synthetic six-sensor pack for connected facilities.",
        "price_cents": 8400,
    },
    {
        "id": "gateway",
        "category": "equipment",
        "name": "Edge gateway",
        "description": "A synthetic industrial gateway for your next deployment.",
        "price_cents": 24900,
    },
]


class CosmosStore:
    def __init__(self):
        # Lazy imports keep injected, offline tests independent of the Azure SDK.
        from azure.cosmos import CosmosClient
        from azure.identity import ManagedIdentityCredential

        self.credential = ManagedIdentityCredential(
            client_id=os.environ["AZURE_CLIENT_ID"],
            connection_timeout=1, read_timeout=2, retry_total=0
        )
        try:
            self.client = CosmosClient(
                os.environ["COSMOS_ENDPOINT"],
                credential=self.credential,
                connection_timeout=1,
                read_timeout=2,
                timeout=3,
                retry_total=0,
                retry_connect=0,
                retry_read=0,
                retry_status=0,
                retry_write=0,
                enable_endpoint_discovery=False,
            )
        except Exception:
            self.credential.close()
            raise
        database = self.client.get_database_client(os.getenv("COSMOS_DATABASE", "orderflow"))
        self.products = database.get_container_client("products")
        self.orders = database.get_container_client("orders")

    def seed(self):
        from azure.cosmos.exceptions import CosmosResourceExistsError

        # Only first initialization seeds immutable synthetic catalog documents.
        # Never upsert: existing data is not overwritten or silently repaired.
        for product in CATALOG:
            with suppress(CosmosResourceExistsError):
                self.products.create_item(dict(product))

    def health(self):
        Product.model_validate(
            self.products.read_item(item="field-kit", partition_key="equipment")
        )
        self.orders.read()
        return {"status": "healthy", "dependency": "cosmos"}

    def catalog(self):
        return {
            "products": [
                Product.model_validate(
                    self.products.read_item(item=p["id"], partition_key="equipment")
                ).model_dump()
                for p in CATALOG
            ]
        }

    def lookup(self, request_id):
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        try:
            return Receipt.model_validate(
                self.orders.read_item(item=str(request_id), partition_key=str(request_id))
            ).model_dump(mode="json")
        except CosmosResourceNotFoundError:
            raise HTTPException(404, "Receipt not found. Outcome remains unconfirmed.") from None

    def order(self, order):
        from azure.cosmos.exceptions import CosmosResourceExistsError

        product = Product.model_validate(
            self.products.read_item(item=order.product_id, partition_key="equipment")
        )
        receipt = Receipt(
            id=order.request_id,
            request_id=order.request_id,
            product_id=order.product_id,
            quantity=order.quantity,
            total_cents=product.price_cents * order.quantity,
            created_at=datetime.now(UTC).isoformat(),
        ).model_dump(mode="json")
        try:
            self.orders.create_item(receipt)
            return receipt
        except CosmosResourceExistsError:
            previous = self.lookup(order.request_id)
            if (
                previous["product_id"] != order.product_id
                or previous["quantity"] != order.quantity
            ):
                raise HTTPException(409, "Request ID already belongs to another order.") from None
            return previous

    def close(self):
        self.client.close()
        self.credential.close()


def create_app(store=None):
    lock = threading.Lock()
    repository = store

    @asynccontextmanager
    async def lifespan(_app):
        configure_telemetry()
        try:
            yield
        finally:
            if repository is not None and hasattr(repository, "close"):
                await run_in_threadpool(repository.close)

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    protect(app)

    def invoke(operation, argument):
        nonlocal repository
        with lock:
            if repository is None:
                candidate = CosmosStore()
                try:
                    candidate.seed()
                except Exception:
                    candidate.close()
                    raise
                repository = candidate
        method = getattr(repository, operation)
        return method() if argument is None else method(argument)

    async def call(operation, argument=None, request_id=None):
        started = time.perf_counter()
        success = False
        try:
            result = await run_in_threadpool(invoke, operation, argument)
            success = True
            return result
        except HTTPException:
            raise
        except Exception:
            detail = (
                "Order outcome unknown. Read the receipt using the same request ID; do not retry."
                if operation == "order"
                else "Cosmos dependency unavailable."
            )
            raise HTTPException(503, detail) from None
        finally:
            dependency_event(f"cosmos.{operation}", success, started, request_id)

    @app.get("/api/health", response_model=Health)
    async def health():
        return await call("health")

    @app.get("/api/products", response_model=Catalog)
    async def products():
        return await call("catalog")

    @app.post("/api/orders", response_model=Receipt)
    async def order(body: OrderRequest):
        return await call("order", body, body.request_id)

    @app.get("/api/orders/{request_id}", response_model=Receipt)
    async def receipt(request_id: UUID):
        return await call("lookup", request_id, request_id)

    return app


app = create_app()
