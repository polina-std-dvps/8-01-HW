import pika
from settings import URI

params = pika.URLParameters(URI)
conn = pika.BlockingConnection(params)
channel = conn.channel()

channel.queue_declare(queue="hello")  # <-- тоже hello

def callback(ch, method, properties, body):
    print(f"Received: {body.decode()}")

channel.basic_consume(
    queue="hello",  # <-- и тут
    on_message_callback=callback,
    auto_ack=True
)

print("Waiting for messages...")
channel.start_consuming()
