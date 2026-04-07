# Module 2 Summary (in-progress)

## State Schema

StateGraph can take a state schema.

state schema can be defined in python classes with several different ways.

### Using TypedDict

```python
from typing_extensions import TypedDict

class SomeState(TypedDict):
    foo: str
    bar: str

...

def some_foo_node(state):
    return {"foo": "foo foo foo"}

def some_bar_node(state):
    return {"bar": "bar bar bar"}

builder = StateGraph(SomeState)
builder.add_node("some_foo_node", some_foo_node)
builder.add_node("some_bar_node", some_bar_node)
builder.add_edge(START, "some_foo_node")
builder.add_edge("some_foo_node", "some_bar_node")
builder.add_edge("some_bar_node", END)
```

### Using dataclasses

```python
from dataclasses import dataclass

@dataclass
class SomeState:
    foo: str
    bar: str

...

def some_foo_node(state):
    return {"foo": "foo foo foo"}

def some_bar_node(state):
    return {"bar": "bar bar bar"}

builder = StateGraph(SomeState)
builder.add_node("some_foo_node", some_foo_node)
builder.add_node("some_bar_node", some_bar_node)
builder.add_edge(START, "some_foo_node")
builder.add_edge("some_foo_node", "some_bar_node")
builder.add_edge("some_bar_node", END)
```

### Using Pydantic (seems like typescript zod)

```python
from pydantic import BaseModel, field_validator, ValidationError

class PydanticState(BaseModel):
    name: str
    mood: str # "happy" or "sad"

    @field_validator('mood')
    @classmethod
    def validate_mood(cls, value):
        # Ensure the mood is either "happy" or "sad"
        if value not in ["happy", "sad"]:
            raise ValueError("Each mood must be either 'happy' or 'sad'")
        return value

try:
    state = PydanticState(name="John Doe", mood="mad")
except ValidationError as e:
    print("Validation Error:", e)

...

def node_1(state):
    print("---Node 1---")
    return {"name": state['name'] + " is ... "}

def node_2(state):
    print("---Node 2---")
    return {"mood": "happy"}

def node_3(state):
    print("---Node 3---")
    return {"mood": "sad"}

def decide_mood(state) -> Literal["node_2", "node_3"]:

    # Here, let's just do a 50 / 50 split between nodes 2, 3
    if random.random() < 0.5:

        # 50% of the time, we return Node 2
        return "node_2"

    # 50% of the time, we return Node 3
    return "node_3"

builder = StateGraph(PydanticState)
builder.add_node("node_1", node_1)
builder.add_node("node_2", node_2)
builder.add_node("node_3", node_3)

# Logic
builder.add_edge(START, "node_1")
builder.add_conditional_edges("node_1", decide_mood)
builder.add_edge("node_2", END)
builder.add_edge("node_3", END)
```

## State Reducer
