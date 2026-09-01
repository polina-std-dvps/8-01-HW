import pika
from settings import URI

params = pika.URLParameters(URI)
conn = pika.BlockingConnection(params)
channel = conn.channel()

channel.queue_declare(queue="hello")

if __name__ == "__main__":
    count = 0
    total = 5
    while count < total:
        channel.basic_publish(
            exchange="",
            routing_key="hello",
            body=f"Hello, SYSDB-32! - {count}",
        )
        print(f"Sent: Hello, SYSDB-32! - {count}")
        count += 1
    conn.close()
    print("Done.")
