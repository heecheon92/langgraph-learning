# Module 2 Summary

Module 2 goes deeper on state and memory.
If Module 1 taught "how to build a graph and get it running," Module 2 teaches "how to shape state carefully so a chatbot stays useful over time."

The module builds in a clear progression:

1. Define state schemas more deliberately.
2. Control how state updates merge with reducers.
3. Separate internal graph state from public input/output.
4. Manage message growth with filtering and trimming.
5. Add summarization so the chatbot keeps compressed context.
6. Add persistence so that context survives across graph invocations.
7. Move persistence from in-memory to an external database.

The runnable Studio example for this module is:

- `module-2/studio/chatbot.py`
- `module-2/studio/langgraph.json`

## 1. State schema options

LangGraph lets you define state in a few different ways, and Module 2 makes the tradeoffs clearer than Module 1 did.

### TypedDict

`TypedDict` is the lightest-weight option.
It gives you type hints and editor support, but it does not validate values at runtime.

```python
from typing_extensions import TypedDict

class State(TypedDict):
    foo: str
    bar: str
```

Use it when:

- you want low ceremony
- you already trust the inputs
- you mainly care about readability and IDE support

### Dataclass

Dataclasses make state feel more object-like.
You access fields with dot syntax, but node updates still return dictionaries.

```python
from dataclasses import dataclass

@dataclass
class State:
    name: str
    mood: str

def node(state: State):
    return {"name": state.name + " updated"}
```

Use it when:

- you prefer attribute access like `state.name`
- you want structured Python objects without full validation

### Pydantic

Pydantic is the strict option.
It adds runtime validation, which is useful when invalid state would be dangerous or expensive.

```python
from pydantic import BaseModel, field_validator

class State(BaseModel):
    name: str
    mood: str

    @field_validator("mood")
    @classmethod
    def validate_mood(cls, value):
        if value not in ["happy", "sad"]:
            raise ValueError("invalid mood")
        return value
```

Use it when:

- state correctness matters at runtime
- you want validation errors early
- you expect state from messy or external sources

## 2. Reducers: how concurrent updates merge

One of the most important ideas in Module 2 is that state shape is only half the story.
The other half is update behavior.

Without a reducer, a state key is overwritten.

```python
class State(TypedDict):
    foo: int

def node_1(state):
    return {"foo": state["foo"] + 1}
```

This is fine in a linear graph.
It becomes a problem when two branches update the same key in the same step.

That is why reducers exist: they tell LangGraph how to combine competing updates.

### Example: append values instead of overwrite

```python
from operator import add
from typing import Annotated
from typing_extensions import TypedDict

class State(TypedDict):
    foo: Annotated[list[int], add]
```

Now updates to `foo` are merged with list concatenation.

The lesson here is broader than just syntax:

- state keys are channels
- reducers define channel merge rules
- parallel branches need explicit merge semantics

### Custom reducers

Module 2 also shows that built-in reducers are not always enough.
If you need special handling for `None`, empty inputs, or custom merge logic, define your own reducer.

```python
def reduce_list(left: list | None, right: list | None) -> list:
    if not left:
        left = []
    if not right:
        right = []
    return left + right
```

This is useful because real-world state is often messier than demo state.

## 3. Messages are a special state channel

Module 2 reinforces something introduced in Module 1:
messages are not just a list you happen to store in state.
They are important enough that LangGraph gives them special support.

`MessagesState` already includes:

- a `messages` key
- the `add_messages` reducer

So these are conceptually equivalent:

```python
from typing import Annotated
from typing_extensions import TypedDict
from langchain_core.messages import AnyMessage
from langgraph.graph.message import add_messages

class CustomState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
```

```python
from langgraph.graph import MessagesState

class State(MessagesState):
    pass
```

### Why `add_messages` matters

It does more than just append.
It also supports:

- replacing a message if the incoming message has the same ID
- removing messages when you return `RemoveMessage`

That means message history can be edited, not just extended.

Small example:

```python
from langchain_core.messages import RemoveMessage

delete_messages = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
return {"messages": delete_messages}
```

This is the key mechanism behind the later summarization flow.

## 4. Multiple schemas: public vs private state

This lesson is useful because it makes LangGraph feel less like a toy pipeline and more like a real application structure.

Sometimes your graph needs temporary internal values that should not appear in external input/output.

### Private intermediate state

```python
class OverallState(TypedDict):
    foo: int

class PrivateState(TypedDict):
    baz: int

def node_1(state: OverallState) -> PrivateState:
    return {"baz": state["foo"] + 1}

def node_2(state: PrivateState) -> OverallState:
    return {"foo": state["baz"] + 1}
```

The point is:

- internal nodes can communicate through extra channels
- public graph output does not need to expose those internal channels

### Separate input and output schemas

You can also constrain what the graph accepts and returns.

```python
class InputState(TypedDict):
    question: str

class OutputState(TypedDict):
    answer: str

class OverallState(TypedDict):
    question: str
    answer: str
    notes: str

graph = StateGraph(
    OverallState,
    input_schema=InputState,
    output_schema=OutputState,
)
```

This is valuable because it separates:

- internal working state
- external interface contracts

That is a useful design habit for larger graphs.

## 5. Filtering and trimming messages

This lesson starts the module’s transition from state theory into chatbot practicality.

The problem is straightforward:
if you keep passing the full message history into the model forever, latency and token cost keep growing.

Module 2 shows three different strategies.

### A. Delete older messages from state

This actually changes graph state.

```python
def filter_messages(state: MessagesState):
    delete_messages = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
    return {"messages": delete_messages}
```

Use this when:

- you want the state itself to become smaller
- older messages are no longer useful in raw form

### B. Filter only what the model sees

This does not change state.
It only changes what is sent into the LLM call.

```python
def chat_model_node(state: MessagesState):
    return {"messages": [llm.invoke(state["messages"][-1:])]}
```

Use this when:

- you want to preserve full internal history
- you only want to limit the prompt window

### C. Trim by token budget

This is more precise than slicing by message count.

```python
from langchain_core.messages import trim_messages

messages = trim_messages(
    state["messages"],
    max_tokens=100,
    strategy="last",
    token_counter=ChatOpenAI(model="gpt-4o"),
    allow_partial=True,
)
```

Use this when:

- token budget matters more than message count
- message lengths vary a lot

## 6. Chatbot summarization

This is the most application-oriented part of Module 2.

Instead of just deleting older messages, the graph first compresses them into a running summary.
That summary is then fed back into future model calls.

This gives the chatbot a compact memory of earlier conversation without sending the entire raw transcript every time.

### State shape

The module extends `MessagesState` with a custom `summary` field.

```python
from langgraph.graph import MessagesState

class State(MessagesState):
    summary: str
```

This is a nice pattern because it separates:

- recent detailed conversation in `messages`
- compressed long-range context in `summary`

### Conversation node

When a summary exists, it is injected as a system message before the recent messages.

```python
def call_model(state: State):
    summary = state.get("summary", "")

    if summary:
        system_message = f"Summary of conversation earlier: {summary}"
        messages = [SystemMessage(content=system_message)] + state["messages"]
    else:
        messages = state["messages"]

    response = model.invoke(messages)
    return {"messages": response}
```

Conceptually:

- the summary gives the model high-level continuity
- the recent messages preserve immediate detail and tone

### Summarization node

When the conversation gets long enough, the graph creates or extends the summary, then removes older raw messages.

```python
def summarize_conversation(state: State):
    summary = state.get("summary", "")

    if summary:
        summary_message = (
            f"This is summary of the conversation to date: {summary}\n\n"
            "Extend the summary by taking into account the new messages above:"
        )
    else:
        summary_message = "Create a summary of the conversation above:"

    messages = state["messages"] + [HumanMessage(content=summary_message)]
    response = model.invoke(messages)

    delete_messages = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
    return {"summary": response.content, "messages": delete_messages}
```

This is a clever structure because it does not force a choice between:

- keeping everything forever
- deleting everything blindly

It preserves meaning while controlling prompt growth.

### Routing to summarization

The summary node is only invoked when the conversation exceeds a threshold.

```python
def should_continue(state: State):
    if len(state["messages"]) > 6:
        return "summarize_conversation"
    return END
```

This threshold is simplistic, but the pattern is the real lesson.
In a production system, you might trigger summarization based on:

- token usage
- cost budget
- elapsed turns
- conversation topic shifts

## 7. Why summary and memory persistence are both useful

This is the place where it is easy to get confused.
They are related, but they solve different problems.

### Summary solves prompt compression

A summary helps the model remember earlier context in compressed form.
It is mainly about:

- reducing token usage
- keeping the prompt manageable
- retaining the gist of older turns after raw messages are removed

If you only summarize but do not persist state, that summary disappears after the invocation ends.

### Memory persistence solves continuity across invocations

A checkpointer like `MemorySaver` or `SqliteSaver` preserves graph state so that later invocations can continue where earlier ones stopped.

It is mainly about:

- continuity between separate runs
- resumability after interruptions
- thread-based conversational history

If you only persist raw state without summarization, the stored conversation may keep growing, and later model calls may still become expensive if you keep replaying too much detailed history.

### Why using both is beneficial

Using both together gives you durable compressed memory.

That means:

- the checkpointer preserves the summary and recent messages across runs
- the summary keeps old context small enough to be practical
- the recent messages keep the chatbot grounded in the latest details

The practical division is:

- summary = compression strategy
- persistence = storage strategy

Or more directly:

- summarization decides what form of memory is efficient for the model
- checkpointers decide whether that memory survives into the next invocation

### A good mental model

Think of the conversation state as having two layers:

- short-term detailed memory: the latest few raw messages
- long-term compressed memory: the running summary

And then persistence sits underneath both:

- `MemorySaver` / `SqliteSaver` stores those layers between runs

So the combined system is:

1. recent messages for local detail
2. summary for compressed older context
3. checkpointer for cross-invocation continuity

That is why a chatbot with both summary and persistence is often better than a chatbot with only one of them.

## 8. MemorySaver vs external database memory

The module then upgrades from in-memory persistence to database-backed persistence.

### MemorySaver

`MemorySaver` is the easiest way to add persistence during development.

```python
from langgraph.checkpoint.memory import MemorySaver

memory = MemorySaver()
graph = workflow.compile(checkpointer=memory)
```

It is useful because:

- setup is trivial
- it is perfect for local experiments
- it demonstrates the thread/checkpoint model clearly

But it is still in-memory storage.
It is convenient, not durable infrastructure.

### SqliteSaver

The external-memory lesson uses SQLite to persist checkpoints to a database file.

```python
import sqlite3
from langgraph.checkpoint.sqlite import SqliteSaver

conn = sqlite3.connect("state_db/example.db", check_same_thread=False)
memory = SqliteSaver(conn)
graph = workflow.compile(checkpointer=memory)
```

This matters because now state survives beyond:

- a single invocation
- a single process
- even a notebook restart, as long as the DB file remains

So the teaching progression is:

- `MemorySaver` explains the concept of persistence
- `SqliteSaver` shows how persistence becomes operationally durable

## 9. Threads are the identity layer for memory

Once a checkpointer is involved, the graph needs a stable identifier for which conversation to load.
That is what `thread_id` is for.

```python
config = {"configurable": {"thread_id": "1"}}
graph.invoke({"messages": [HumanMessage(content="hi!")]}, config)
```

Without a thread ID, the system does not know which saved state timeline to continue.

This is especially important in chatbot scenarios because:

- each user may need separate memory
- each session may need separate memory
- summarization should belong to the correct conversation thread

## 10. Studio example in this module

The Studio app in `module-2/studio/chatbot.py` is the best compact representation of the module.
It combines:

- `MessagesState`
- a custom `summary` field
- a conversation node
- a summarization node
- `RemoveMessage`
- a conditional summarization trigger

That file is useful because it shows the final pattern in a relatively small amount of code.

## What Module 2 is really teaching

Module 2 is not just "more memory features."
It is teaching that memory quality depends on both structure and lifecycle.

You need to think about:

- how state is shaped
- how updates merge
- which parts of state are internal vs external
- how message history grows
- when old detail should be compressed
- where state is stored between runs

That is a much more realistic mental model for production chatbots than simply "store the whole conversation forever."

## My takeaway

The deepest lesson in Module 2 is that memory is not a single feature.
It is a combination of:

- schema design
- reducer behavior
- message management
- summarization policy
- persistence backend

The module’s chatbot summarization pattern makes this especially clear:
the summary is not a replacement for persistence, and persistence is not a replacement for summarization.
They are complementary layers that make long-running conversations both cheaper and more durable.
