"""Azure Service Bus producer for the KEDA tutorial.

Sends MESSAGE_COUNT messages to the queue and exits, so it can run as a Kubernetes Job. The
backlog it leaves behind is what the KEDA azure-servicebus scaler observes to scale the consumer
Deployment out from zero.

Azure uses workload identity. The emulator uses its namespace connection string because its
plain-TCP AMQP listener does not support Microsoft Entra authentication.
"""

import logging
import os
import queue
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack

from azure.identity import WorkloadIdentityCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("producer")

# Messages per send call. Batching keeps the Job short without hiding progress from the log.
SEND_BATCH_SIZE = 20
MAX_CONCURRENT_SENDERS = 8
PROGRESS_LOG_INTERVAL = 1000


def required_environment_variable(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        LOG.error("The required environment variable [%s] is not set", name)
        sys.exit(1)
    return value


def _send_worker(
    batch_queue: queue.Queue,
    completed_queue: queue.Queue,
    ready_queue: queue.Queue,
    namespace: str | None,
    connection_string: str | None,
    queue_name: str,
) -> None:
    with ExitStack() as stack:
        try:
            if namespace:
                credential = stack.enter_context(WorkloadIdentityCredential())
                service_bus_client = ServiceBusClient(
                    fully_qualified_namespace=namespace, credential=credential
                )
            else:
                service_bus_client = ServiceBusClient.from_connection_string(connection_string)
            client = stack.enter_context(service_bus_client)
            sender = stack.enter_context(client.get_queue_sender(queue_name=queue_name))
        except Exception as error:
            ready_queue.put(error)
            raise

        ready_queue.put(None)
        while True:
            messages = batch_queue.get()
            try:
                if messages is None:
                    return
                sender.send_messages(messages)
                completed_queue.put((len(messages), time.monotonic()))
            finally:
                batch_queue.task_done()


def _check_workers(workers: list) -> None:
    for worker in workers:
        if worker.done():
            worker.result()
            raise RuntimeError("A producer sender worker stopped unexpectedly")


def _put_work_item(batch_queue: queue.Queue, item: list | None, workers: list) -> None:
    while True:
        _check_workers(workers)
        try:
            batch_queue.put(item, timeout=0.1)
            return
        except queue.Full:
            continue


def _stop_workers(batch_queue: queue.Queue, workers: list) -> None:
    for worker in workers:
        while not worker.done() and not all(item.done() for item in workers):
            try:
                batch_queue.put(None, timeout=0.1)
                break
            except queue.Full:
                continue


def _log_completed(
    completed_queue: queue.Queue,
    completed: int,
    message_count: int,
) -> int:
    while True:
        try:
            count, _ = completed_queue.get_nowait()
        except queue.Empty:
            return completed
        completed += count
        if completed % PROGRESS_LOG_INTERVAL == 0 or completed == message_count:
            LOG.info("Sent [%s] of [%s] messages", completed, message_count)


def send_messages(
    namespace: str | None,
    connection_string: str | None,
    queue_name: str,
    message_count: int,
    target_rate: int,
) -> None:
    worker_count = min(
        MAX_CONCURRENT_SENDERS,
        max(1, (message_count + SEND_BATCH_SIZE - 1) // SEND_BATCH_SIZE),
    )
    batch_queue = queue.Queue(maxsize=worker_count * 2)
    completed_queue = queue.Queue()
    ready_queue = queue.Queue()

    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        workers = [
            executor.submit(
                _send_worker,
                batch_queue,
                completed_queue,
                ready_queue,
                namespace,
                connection_string,
                queue_name,
            )
            for _ in range(worker_count)
        ]
        completed = 0
        try:
            ready_workers = 0
            while ready_workers < worker_count:
                try:
                    result = ready_queue.get(timeout=0.1)
                except queue.Empty:
                    _check_workers(workers)
                    continue
                if isinstance(result, BaseException):
                    raise result
                ready_workers += 1

            started_at = time.monotonic()
            next_send_at = started_at
            submitted = 0
            while submitted < message_count:
                batch_size = min(SEND_BATCH_SIZE, message_count - submitted)
                delay = next_send_at - time.monotonic()
                if delay > 0:
                    time.sleep(delay)

                was_full = batch_queue.full()
                messages = [
                    ServiceBusMessage(f"work-item-{submitted + i}") for i in range(batch_size)
                ]
                _put_work_item(batch_queue, messages, workers)
                submitted += batch_size
                next_send_at += batch_size / target_rate
                if was_full:
                    next_send_at = max(next_send_at, time.monotonic())
                completed = _log_completed(completed_queue, completed, message_count)

            _stop_workers(batch_queue, workers)
            for worker in workers:
                worker.result()
            completed = _log_completed(completed_queue, completed, message_count)
            elapsed = time.monotonic() - started_at
        finally:
            _stop_workers(batch_queue, workers)

    achieved_rate = completed / elapsed if elapsed > 0 else 0
    LOG.info(
        "Completed [%s] messages in [%.2f] seconds (%.0f messages/second; target [%s])",
        completed,
        elapsed,
        achieved_rate,
        target_rate,
    )


def main() -> None:
    namespace = os.environ.get("SERVICEBUS_FULLY_QUALIFIED_NAMESPACE")
    queue_name = required_environment_variable("QUEUE_NAME")
    message_count = int(os.environ.get("MESSAGE_COUNT", "100"))
    target_rate = int(os.environ.get("MESSAGE_RATE_PER_SECOND", "1000"))
    if target_rate <= 0:
        LOG.error("The [MESSAGE_RATE_PER_SECOND] value must be greater than zero")
        sys.exit(1)

    LOG.info(
        "Sending [%s] messages to the [%s] queue at a target rate of [%s] messages per second...",
        message_count,
        queue_name,
        target_rate,
    )
    connection_string = None
    if not namespace:
        connection_string = required_environment_variable("SERVICEBUS_CONNECTION")
    send_messages(namespace, connection_string, queue_name, message_count, target_rate)
    LOG.info("Done: [%s] messages are queued in [%s]", message_count, queue_name)


if __name__ == "__main__":
    main()
