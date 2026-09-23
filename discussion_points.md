* The little time-data overview graph in the variable boxes now always starts at 1900. There are some variables which have data all the way back to 1789, but they are a minority and setting zero at 1789 would compress all the other charts quite a lot.

It's more visually appealing to the user if we start at 1900, but it's less correct.

We could also not sync the starting year  between the charts and just let them all start at whatever year they start at, but then we need to write out the start and end years for each chart.


* British english or american english?

* A table representation of the map data needs to be added in order to support screen-readers, but this will expose country names.

* 